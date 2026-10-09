import Foundation
import IOBluetooth
import SQLite3

// 鸿蒙短信 → Mac 增量同步
//
// 只同步绑定之后新到达的短信：拉一次收件箱列表 → 与已见 handle 比对 →
// 对新增的取正文 → 弹系统通知 → 落库。
//
// 用法:
//   ./HarmonySync                      持续轮询
//   ./HarmonySync --once               只跑一轮就退出
//   ./HarmonySync --reset --once       清空本地记录后重新建立基线
//   ./HarmonySync <设备地址> [通道]

// MARK: - 配置

let DEVICE_DEFAULT = "E8-1E-92-55-2D-D4"
let CHANNEL_DEFAULT: UInt8 = 26
var pollInterval: Double = 5.0           // 轮询间隔（秒），--interval 可改
var mnsEnabled = true                    // --no-mns 可关掉事件订阅
let LISTING_LIMIT: UInt16 = 20          // 每次只取最新的 N 条
let MAX_CHUNKS = 80
let STEP_TIMEOUT: Double = 15.0
let RETRY_DELAY: Double = 8.0

let HOME = NSHomeDirectory()
let DB_DIR = HOME + "/Library/Application Support/HarmonySync"
let DB_PATH = DB_DIR + "/messages.db"
let LOG_PATH = "/tmp/harmony_sync_result.txt"

var logBuffer = ""
func emit(_ items: Any...) {
    let line = items.map { String(describing: $0) }.joined(separator: " ")
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let out = "[\(stamp)] \(line)"
    print(out)
    logBuffer += out + "\n"
    try? logBuffer.write(toFile: LOG_PATH, atomically: true, encoding: .utf8)
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// MARK: - OBEX 常量

let OBEX_CONNECT: UInt8 = 0x80
let OBEX_GET_FINAL: UInt8 = 0x83
let OBEX_SETPATH: UInt8 = 0x85
let OBEX_PUT_FINAL: UInt8 = 0x82

let HDR_NAME: UInt8 = 0x01
let HDR_TYPE: UInt8 = 0x42
let HDR_TARGET: UInt8 = 0x46
let HDR_BODY: UInt8 = 0x48
let HDR_END_OF_BODY: UInt8 = 0x49
let HDR_APPPARAMS: UInt8 = 0x4C
let HDR_CONNID: UInt8 = 0xCB

let MAS_UUID: [UInt8] = [
    0xBB, 0x58, 0x2B, 0x40, 0x42, 0x0C, 0x11, 0xDB,
    0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
]

let FOLDER_PATH = ["telecom", "msg", "inbox"]
let LISTING_TYPE = "x-bt/MAP-msg-listing"
let NOTIF_REG_TYPE = "x-bt/MAP-NotificationRegistration"

func lenHeader(_ id: UInt8, _ value: [UInt8]) -> [UInt8] {
    let total = value.count + 3
    return [id, UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)] + value
}

func utf16be(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    for unit in s.utf16 {
        out.append(UInt8((unit >> 8) & 0xFF))
        out.append(UInt8(unit & 0xFF))
    }
    return out
}

func frame(opcode: UInt8, body: [UInt8]) -> [UInt8] {
    let total = 3 + body.count
    return [opcode, UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)] + body
}

// MARK: - 列表解析

struct Sms {
    var handle = ""
    var subject = ""
    var datetime = ""
    var peerNumber = ""
    var peerName = ""
    var isRead = ""
    var type = ""
}

// 列表里 msg 元素的属性名。手机生成的 XML 存在未转义的引号（短信正文里出现
// 英文引号时），XMLParser 会在那一处中断、丢掉后面全部记录，因此按属性名自行扫描。
let LISTING_KEYS = [
    "handle", "subject", "datetime", "sender_name", "sender_addressing",
    "recipient_name", "recipient_addressing", "type", "size", "text",
    "reception_status", "attachment_size", "priority", "read", "sent", "protected",
]

func tagAttributes(_ tag: Substring) -> [String: String] {
    var values: [String: String] = [:]
    for (i, key) in LISTING_KEYS.enumerated() {
        let head = (i == 0 ? "" : " ") + key + "=\""
        guard let kr = tag.range(of: head) else { continue }
        let valueStart = kr.upperBound
        var valueEnd = tag.endIndex
        for other in LISTING_KEYS where other != key {
            if let or = tag.range(of: " " + other + "=\"", range: valueStart..<tag.endIndex),
               or.lowerBound < valueEnd {
                valueEnd = or.lowerBound
            }
        }
        var value = String(tag[valueStart..<valueEnd])
        while let last = value.last, last == "\"" || last == " " { value.removeLast() }
        values[key] = value
    }
    return values
}

func parseListing(_ raw: String) -> [Sms] {
    var text = raw
    if let r = raw.range(of: "<?xml", options: .backwards) {
        text = String(raw[r.lowerBound...])
    }
    var out: [Sms] = []
    var cursor = text.startIndex

    while let tagStart = text.range(of: "<msg ", range: cursor..<text.endIndex) {
        guard let tagEnd = text.range(of: "/>", range: tagStart.upperBound..<text.endIndex) else { break }
        let values = tagAttributes(text[tagStart.upperBound..<tagEnd.lowerBound])

        var m = Sms()
        m.handle = values["handle"] ?? ""
        m.subject = values["subject"] ?? ""
        m.datetime = values["datetime"] ?? ""
        m.peerName = values["sender_name"] ?? ""
        m.peerNumber = values["sender_addressing"] ?? ""
        m.isRead = values["read"] ?? ""
        m.type = values["type"] ?? ""
        if !m.handle.isEmpty { out.append(m) }

        cursor = tagEnd.upperBound
    }
    return out
}

// MAP 的时间戳格式 20261009T104036
func prettyTime(_ stamp: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd'T'HHmmss"
    f.timeZone = TimeZone.current
    guard let d = f.date(from: stamp) else { return stamp }
    let out = DateFormatter()
    out.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return out.string(from: d)
}

// MARK: - 存储

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Store {
    var db: OpaquePointer?

    init?(path: String) {
        try? FileManager.default.createDirectory(atPath: DB_DIR, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            emit("✗ 打不开数据库 \(path)")
            return nil
        }
        exec("""
        CREATE TABLE IF NOT EXISTS seen_handle (
          handle      TEXT PRIMARY KEY,
          stamp       TEXT NOT NULL,
          first_seen  INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS message (
          id           INTEGER PRIMARY KEY,
          handle       TEXT NOT NULL UNIQUE,
          peer_number  TEXT,
          peer_name    TEXT,
          body         TEXT,
          stamp        TEXT,
          received_at  INTEGER NOT NULL,
          notified_at  INTEGER
        );
        CREATE TABLE IF NOT EXISTS sync_state (
          key   TEXT PRIMARY KEY,
          value TEXT
        );
        """)
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let e = err {
            emit("✗ SQL 出错：\(String(cString: e))")
            sqlite3_free(err)
        }
    }

    func isSeen(_ handle: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM seen_handle WHERE handle = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, handle, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func remember(_ handle: String, stamp: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO seen_handle (handle, stamp, first_seen) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, handle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, stamp, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
        sqlite3_step(stmt)
    }

    func saveMessage(_ m: Sms, notified: Bool) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT OR IGNORE INTO message
          (handle, peer_number, peer_name, body, stamp, received_at, notified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, m.handle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, m.peerNumber, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, m.peerName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, m.subject, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, m.datetime, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970))
        if notified {
            sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970))
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_step(stmt)
    }

    func count(_ table: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func state(_ key: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM sync_state WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func setState(_ key: String, _ value: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // 已见记录只保留近 120 天，避免无限增长
    func prune(_ cutoff: String) {
        exec("DELETE FROM seen_handle WHERE stamp <> '' AND stamp < '\(cutoff)'")
    }
}

// MARK: - 通知

func applescriptQuote(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"" + escaped + "\""
}

func notify(title: String, body: String) {
    let script = "display notification \(applescriptQuote(body)) with title \(applescriptQuote(title)) sound name \"default\""
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    do {
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { emit("  ⚠ 通知未弹出（osascript 返回 \(p.terminationStatus)）") }
    } catch {
        emit("  ⚠ 通知失败：\(error)")
    }
}

// MARK: - OBEX 报文解析

func parseObexHeaders(_ bytes: [UInt8]) -> [(UInt8, [UInt8])] {
    var out: [(UInt8, [UInt8])] = []
    var i = 3
    while i < bytes.count {
        let id = bytes[i]
        switch id & 0xC0 {
        case 0x00:
            guard i + 1 < bytes.count else { return out }
            out.append((id, [bytes[i + 1]]))
            i += 2
        case 0x40:
            guard i + 2 < bytes.count else { return out }
            let len = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            guard len >= 3, i + len <= bytes.count else { return out }
            out.append((id, Array(bytes[(i + 3)..<(i + len)])))
            i += len
        case 0x80:
            guard i + 2 < bytes.count else { return out }
            out.append((id, [bytes[i + 1], bytes[i + 2]]))
            i += 3
        default:
            guard i + 4 < bytes.count else { return out }
            out.append((id, Array(bytes[(i + 1)...(i + 4)])))
            i += 5
        }
    }
    return out
}

// 从 AppParams 里取一个标签的值（格式：标签 1 字节 + 长度 1 字节 + 值）
func appParam(_ data: [UInt8], tag: UInt8) -> UInt8? {
    var i = 0
    while i + 1 < data.count {
        let t = data[i]
        let len = Int(data[i + 1])
        guard i + 2 + len <= data.count else { return nil }
        if t == tag, len >= 1 { return data[i + 2] }
        i += 2 + len
    }
    return nil
}

// MARK: - MNS 服务端

let MNS_UUID16: UInt16 = 0x1133
let MAP_PROFILE_UUID16: UInt16 = 0x1134
let L2CAP_UUID16: UInt16 = 0x0100
let RFCOMM_UUID16: UInt16 = 0x0003
let OBEX_UUID16: UInt16 = 0x0008
let BROWSE_GROUP_UUID16: UInt16 = 0x1002
let MNS_RFCOMM_CHANNEL: UInt8 = 10      // 期望值，被占用时系统会另分配
let EVENT_REPORT_TYPE = "x-bt/MAP-Event-Report"

func sdpUInt16(_ value: UInt16) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data([UInt8(value >> 8), UInt8(value & 0xFF)])]
}

func sdpUInt8(_ value: UInt8) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data([value])]
}

func mnsServiceDict(channel: UInt8) -> [String: Any] {
    [
        "0001 ServiceClassIDList": [IOBluetoothSDPUUID(uuid16: MNS_UUID16)!],
        "0004 ProtocolDescriptorList": [
            [IOBluetoothSDPUUID(uuid16: L2CAP_UUID16)!, sdpUInt16(0x0003)],
            [IOBluetoothSDPUUID(uuid16: RFCOMM_UUID16)!, sdpUInt8(channel)],
            [IOBluetoothSDPUUID(uuid16: OBEX_UUID16)!],
        ],
        "0005 BrowseGroupList": [IOBluetoothSDPUUID(uuid16: BROWSE_GROUP_UUID16)!],
        "0009 BluetoothProfileDescriptorList": [
            [IOBluetoothSDPUUID(uuid16: MAP_PROFILE_UUID16)!, sdpUInt16(0x0102)]
        ],
        "0100 ServiceName": "MAP MNS",
        // 低两位：Notification Registration + Notification
        "0317 SupportedFeatures": ["DataElementType": 1, "DataElementValue": Data([0x00, 0x00, 0x00, 0x03])],
    ]
}

// 手机推事件时连上来的那条通道
final class MnsChannel: NSObject, IOBluetoothRFCOMMChannelDelegate {
    let channel: IOBluetoothRFCOMMChannel
    let onEvent: (String) -> Void
    var rx: [UInt8] = []
    var connID: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    init(channel: IOBluetoothRFCOMMChannel, onEvent: @escaping (String) -> Void) {
        self.channel = channel
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        _ = channel.setDelegate(self)
        emit("  [MNS] 手机已连上（通道 \(channel.getID())），等事件…")
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        rx += Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        while rx.count >= 3 {
            let len = Int(rx[1]) << 8 | Int(rx[2])
            guard len >= 3 else {
                emit("  [MNS] 报文长度异常 \(len)，丢弃缓冲")
                rx.removeAll()
                return
            }
            guard rx.count >= len else { break }
            let packet = Array(rx[0..<len])
            rx.removeFirst(len)
            handle(packet)
        }
    }

    func handle(_ packet: [UInt8]) {
        guard let op = packet.first else { return }
        let headers = parseObexHeaders(packet)
        let type = headers.first { $0.0 == HDR_TYPE }.map { String(decoding: $0.1, as: UTF8.self) } ?? ""
        var body: [UInt8] = []
        for (id, v) in headers where id == HDR_BODY || id == HDR_END_OF_BODY { body += v }

        switch op & 0x7F {
        case 0x00:
            emit("  [MNS] ← CONNECT（\(packet.count) 字节）")
            respond(0xA0)
        case 0x02:
            emit("  [MNS] ← PUT  Type=\(type.isEmpty ? "?" : type)  Body \(body.count) 字节 \(hex(Array(body.prefix(24))))")
            if type == EVENT_REPORT_TYPE {
                let newMessage = appParam(body, tag: 0x01)
                let folder = appParam(body, tag: 0x03)
                let detail = "NewMessage=\(newMessage.map { String($0) } ?? "?")"
                    + (folder != nil ? "  Folder=\(folder!)" : "")
                emit("  [MNS] ★ 事件报告：\(detail)")
                onEvent(detail)
            }
            respond(0xA0)
        case 0x01:
            emit("  [MNS] ← DISCONNECT")
            respond(0xA0)
            _ = channel.close()
        default:
            emit("  [MNS] ← 未知操作 0x\(String(format: "%02X", op))")
            respond(0xA0)
        }
    }

    func respond(_ code: UInt8) {
        let body: [UInt8] = [HDR_CONNID] + connID
        var buf = frame(opcode: code, body: body)
        let rc = channel.writeSync(&buf, length: UInt16(buf.count))
        if rc != kIOReturnSuccess { emit("  [MNS] ✗ 应答写入返回码 \(rc)") }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        emit("  [MNS] 手机断开了事件通道")
    }
}

final class MnsServer: NSObject {
    var record: IOBluetoothSDPServiceRecord?
    var notification: IOBluetoothUserNotification?
    var channels: [MnsChannel] = []
    var onEvent: (String) -> Void = { _ in }
    var channelID: BluetoothRFCOMMChannelID = 0

    func start(onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent

        guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with:
            mnsServiceDict(channel: MNS_RFCOMM_CHANNEL)) else {
            emit("  [MNS] ✗ SDP 记录发布失败")
            return
        }
        record = rec

        var cid: BluetoothRFCOMMChannelID = 0
        if rec.getRFCOMMChannelID(&cid) == kIOReturnSuccess {
            channelID = cid
            emit("  [MNS] ✓ SDP 记录已发布，RFCOMM 通道 \(cid)")
        } else {
            emit("  [MNS] ✓ SDP 记录已发布，未读到通道号")
        }

        notification = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(incoming(_:channel:)),
            withChannelID: channelID,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming)

        if notification != nil {
            emit("  [MNS] 已监听入站连接，等手机回连")
        } else {
            emit("  [MNS] ✗ 入站监听注册失败")
        }
    }

    @objc func incoming(_ note: IOBluetoothUserNotification!, channel: IOBluetoothRFCOMMChannel!) {
        guard let ch = channel else { return }
        emit("")
        emit("  [MNS] 有设备连进来了（通道 \(ch.getID())）")
        let mc = MnsChannel(channel: ch, onEvent: onEvent)
        channels.append(mc)
        mc.start()
    }
}

// MARK: - 同步主体

final class Sync: NSObject, IOBluetoothRFCOMMChannelDelegate {
    let store: Store
    let device: IOBluetoothDevice
    let channelID: BluetoothRFCOMMChannelID
    let once: Bool

    var channel: IOBluetoothRFCOMMChannel?
    var connectionID: [UInt8]?
    var rxBuffer: [UInt8] = []
    var token = 0
    var acc: [UInt8] = []
    var chunks = 0

    enum Phase { case connect, subscribe, setpath, listing, idle }
    var phase: Phase = .connect
    var pathIndex = 0
    var listingParamsSupported: Bool? = nil   // nil = 还没试出来
    var listingTriedFallback = false
    var needFullRetry = false
    var baseline = false
    var pollCount = 0
    var notifVariant = 0
    var notifSupported: Bool? = nil           // nil = 还没试出来
    var awaiting = false
    var pendingPoll: DispatchWorkItem?

    init(store: Store, device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID, once: Bool) {
        self.store = store
        self.device = device
        self.channelID = channelID
        self.once = once
        super.init()
    }

    func start() {
        openSession()
    }

    func openSession() {
        connectionID = nil
        rxBuffer.removeAll()
        acc = []
        chunks = 0
        phase = .connect
        pathIndex = 0
        listingTriedFallback = false
        needFullRetry = false

        if let ch = channel { _ = ch.close() }
        channel = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var ch: IOBluetoothRFCOMMChannel? = nil
            let rc = self.device.openRFCOMMChannelAsync(&ch, withChannelID: self.channelID, delegate: self)
            if rc != kIOReturnSuccess { emit("✗ 打开通道返回码 \(rc)") }
            self.channel = ch
        }
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == kIOReturnSuccess else {
            emit("✗ 通道打开失败 status=\(status)，\(Int(RETRY_DELAY)) 秒后重试")
            scheduleReconnect()
            return
        }
        var body: [UInt8] = [0x10, 0x00, 0xFF, 0xFF]
        body += lenHeader(HDR_TARGET, MAS_UUID)
        send(frame(opcode: OBEX_CONNECT, body: body), note: "Connect")
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        emit("通道已关闭")
        guard phase != .idle else { return }
        scheduleReconnect()
    }

    func scheduleReconnect() {
        phase = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + RETRY_DELAY) { self.openSession() }
    }

    // MARK: 发送

    func withConnID(_ body: [UInt8]) -> [UInt8] {
        guard let cid = connectionID else { return body }
        return [HDR_CONNID] + cid + body
    }

    func send(_ packet: [UInt8], note: String, resetAcc: Bool = true) {
        emit("→ \(note)（\(packet.count) 字节）")
        if resetAcc { acc = []; chunks = 0 }
        awaiting = true
        token += 1
        armTimeout()
        write(packet)
    }

    func armTimeout() {
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + STEP_TIMEOUT) {
            guard t == self.token else { return }
            emit("  ⏱ 无响应，重连")
            self.scheduleReconnect()
        }
    }

    func write(_ bytes: [UInt8]) {
        var buf = bytes
        let rc = channel?.writeSync(&buf, length: UInt16(buf.count))
        if rc != kIOReturnSuccess { emit("  ✗ 写入返回码 \(String(describing: rc))") }
    }

    func sendSetPath(_ folder: String) {
        // SETPATH 不携带 Connection ID
        var body: [UInt8] = [0x00, 0x00]
        body += lenHeader(HDR_NAME, utf16be(folder))
        send(frame(opcode: OBEX_SETPATH, body: body), note: "SETPATH \(folder)")
    }

    // 订阅新消息事件。四种写法依次试：ConnID ±、末尾空 EndOfBody ±
    let NOTIF_VARIANTS = [
        "ConnID + 空 EndOfBody",
        "无 ConnID + 空 EndOfBody",
        "ConnID，无 EndOfBody",
        "无 ConnID，无 EndOfBody",
    ]

    func sendNotifRegistration() {
        var body: [UInt8] = []
        body += lenHeader(HDR_TYPE, Array(NOTIF_REG_TYPE.utf8))
        body += lenHeader(HDR_APPPARAMS, [0x0B, 0x01, 0x01])   // NotificationStatus = on
        if notifVariant < 2 { body += lenHeader(HDR_END_OF_BODY, []) }
        if notifVariant % 2 == 0 { body = withConnID(body) }
        send(frame(opcode: OBEX_PUT_FINAL, body: body),
             note: "订阅新消息事件［\(NOTIF_VARIANTS[notifVariant])］")
    }

    func sendListing(forceFull: Bool = false) {
        var body: [UInt8] = []
        body += lenHeader(HDR_TYPE, Array(LISTING_TYPE.utf8))
        body += lenHeader(HDR_NAME, Array("inbox".utf8))
        // MaxListCount：只要最新的 N 条。服务端不认时下面会退回整份列表。
        let limited = !forceFull && listingParamsSupported != false
        if limited {
            let ap: [UInt8] = [0x01, 0x02, UInt8(LISTING_LIMIT >> 8), UInt8(LISTING_LIMIT & 0xFF)]
            body += lenHeader(HDR_APPPARAMS, ap)
        }
        let note = limited ? "GET 收件箱列表（最新 \(LISTING_LIMIT) 条）" : "GET 收件箱列表（整份）"
        send(frame(opcode: OBEX_GET_FINAL, body: withConnID(body)), note: note)
    }

    func sendContinue() {
        send(frame(opcode: OBEX_GET_FINAL, body: withConnID([])), note: "续传", resetAcc: false)
    }

    // MARK: 接收

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        rxBuffer += Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))

        while rxBuffer.count >= 3 {
            let len = Int(rxBuffer[1]) << 8 | Int(rxBuffer[2])
            guard len >= 3 else {
                emit("  ✗ 报文长度异常 \(len)，丢弃缓冲")
                rxBuffer.removeAll()
                return
            }
            guard rxBuffer.count >= len else { break }
            let packet = Array(rxBuffer[0..<len])
            rxBuffer.removeFirst(len)
            handle(packet)
        }
    }

    func handle(_ bytes: [UInt8]) {
        token += 1
        guard let op = bytes.first else { return }

        let isSuccess = (op & 0xF0) == 0xA0
        let isContinue = (op == 0x90)
        let headers = parseObexHeaders(bytes)

        for (id, value) in headers where id == HDR_CONNID {
            if connectionID == nil {
                connectionID = value
                emit("  Connection ID = \(hex(value))")
            }
        }
        for (id, value) in headers where id == HDR_BODY || id == HDR_END_OF_BODY {
            acc += value
        }

        if isContinue {
            chunks += 1
            if chunks <= MAX_CHUNKS {
                token += 1
                armTimeout()
                sendContinue()
                return
            }
            emit("  ✗ 分片超限")
            scheduleReconnect()
            return
        }

        if !isSuccess {
            emit("  ✗ 响应码 0x\(String(format: "%02X", op))（\(bytes.count) 字节）")

            // 订阅被拒时换一种写法再试
            if phase == .subscribe && notifSupported == nil && notifVariant + 1 < NOTIF_VARIANTS.count {
                notifVariant += 1
                emit("  ↻ 换一种写法：\(NOTIF_VARIANTS[notifVariant])")
                sendNotifRegistration()
                return
            }
            if phase == .subscribe {
                notifSupported = false
                emit("  ⚠ 事件订阅未成功，本机继续用定时拉列表")
                phase = .setpath
                pathIndex = 0
                sendSetPath(FOLDER_PATH[pathIndex])
                return
            }

            // 列表请求带 AppParams 被拒时，退回整份列表
            if phase == .listing && listingParamsSupported != false && !listingTriedFallback {
                listingParamsSupported = false
                listingTriedFallback = true
                emit("  ↻ 该请求形式被拒，改为整份列表")
                sendListing()
                return
            }
            scheduleReconnect()
            return
        }

        awaiting = false

        switch phase {
        case .connect:
            emit("  ✓ 已连接手机")
            if listingParamsSupported == nil { listingParamsSupported = true }
            if mnsEnabled {
                phase = .subscribe
                notifVariant = 0
                sendNotifRegistration()
            } else {
                phase = .setpath
                pathIndex = 0
                sendSetPath(FOLDER_PATH[pathIndex])
            }

        case .subscribe:
            notifSupported = true
            emit("  ✓ 事件订阅成功［\(NOTIF_VARIANTS[notifVariant])］")
            phase = .setpath
            pathIndex = 0
            sendSetPath(FOLDER_PATH[pathIndex])

        case .setpath:
            pathIndex += 1
            if pathIndex < FOLDER_PATH.count {
                sendSetPath(FOLDER_PATH[pathIndex])
            } else {
                emit("  ✓ 已进入 收件箱")
                phase = .listing
                sendListing()
            }

        case .listing:
            finishListing()

        case .idle:
            break
        }
    }

    // MARK: 一轮同步

    func finishListing() {
        let raw = String(decoding: acc, as: UTF8.self)
        let msgs = parseListing(raw)
        pollCount += 1

        if msgs.isEmpty {
            emit("  收件箱列表为空（\(acc.count) 字节）")
            scheduleNextPoll()
            return
        }

        if baseline {
            // 建立基线：只记 handle，不通知、不存正文
            for m in msgs { store.remember(m.handle, stamp: m.datetime) }
            store.setState("bootstrap_at", String(Int(Date().timeIntervalSince1970)))
            baseline = false
            store.prune(cutoffStamp(days: 120))
            emit("  ✓ 已建立基线：\(msgs.count) 条记入已见，不通知")
            emit("  已见 handle 共 \(store.count("seen_handle")) 条")
            scheduleNextPoll()
            return
        }

        var fresh: [Sms] = []
        for m in msgs where !store.isSeen(m.handle) {
            fresh.append(m)
        }

        // 窗口被打满且全是新短信：可能还有更早的新消息落在窗口外，改取整份
        if !needFullRetry && listingParamsSupported != false
            && msgs.count >= Int(LISTING_LIMIT) && fresh.count == msgs.count {
            emit("  窗口已满且 \(fresh.count) 条全新，改取整份列表")
            needFullRetry = true
            sendListing(forceFull: true)
            return
        }
        needFullRetry = false

        if fresh.isEmpty {
            emit("  无新短信（列表 \(msgs.count) 条）")
            scheduleNextPoll()
            return
        }

        // 按时间正序通知，读起来跟手机上一致
        fresh.sort { $0.datetime < $1.datetime }

        emit("")
        emit("  ★ 新短信 \(fresh.count) 条")
        for m in fresh {
            let who = m.peerName.isEmpty ? m.peerNumber : m.peerName
            emit("    [\(prettyTime(m.datetime))] \(who)")
            emit("      \(m.subject)")
            store.remember(m.handle, stamp: m.datetime)
            store.saveMessage(m, notified: true)
            notify(title: "新短信 · \(who)", body: m.subject)
        }
        emit("  ✓ 已通知并入库，本地共 \(store.count("message")) 条")
        emit("")

        scheduleNextPoll()
    }

    func cutoffStamp(days: Int) -> String {
        let d = Date().addingTimeInterval(-Double(days) * 86400)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    func scheduleNextPoll() {
        if once {
            emit("（--once：本轮结束，退出）")
            finish()
            return
        }
        phase = .listing
        emit("  下次轮询 \(Int(pollInterval)) 秒后")
        let item = DispatchWorkItem {
            guard self.channel != nil else { self.openSession(); return }
            self.phase = .listing
            self.sendListing()
        }
        pendingPoll = item
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: item)
    }

    // 手机推来事件时立刻拉一次，不等下一个轮询周期
    func pollNow(_ reason: String) {
        guard !once else { return }
        guard channel != nil else { return }
        guard !awaiting else {
            emit("  [MNS] 事件已到，当前请求未完成，等它跑完")
            return
        }
        guard phase == .listing else { return }
        pendingPoll?.cancel()
        pendingPoll = nil
        emit("  [MNS] 事件触发（\(reason)），立即拉一次列表")
        phase = .listing
        sendListing()
    }

    func finish() {
        if let ch = channel { _ = ch.close() }
        phase = .idle
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

// MARK: - 入口

var args = Array(CommandLine.arguments.dropFirst())

// 本地自检：不连蓝牙，直接拿一份保存下来的列表验解析
if let i = args.firstIndex(of: "--parse"), i + 1 < args.count {
    let path = args[i + 1]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("读不到 \(path)")
        exit(1)
    }
    let tags = text.components(separatedBy: "<msg ").count - 1
    let msgs = parseListing(text)
    print("msg 元素 \(tags) 个，解析出 \(msgs.count) 条")
    print("正文含引号的条数：\(msgs.filter { $0.subject.contains("\"") }.count)")
    print("最新 3 条：")
    for m in msgs.prefix(3) {
        print("  [\(prettyTime(m.datetime))] \(m.peerNumber) — \(m.subject)")
    }
    if let q = msgs.first(where: { $0.subject.contains("\"") }) {
        print("含引号的样例：")
        print("  [\(prettyTime(q.datetime))] \(q.peerNumber) — \(q.subject)")
    }
    exit(0)
}

let once = args.contains("--once")
let reset = args.contains("--reset")
if args.contains("--no-mns") { mnsEnabled = false }
if let i = args.firstIndex(of: "--interval"), i + 1 < args.count,
   let v = Double(args[i + 1]), v >= 1 {
    pollInterval = v
    args.removeSubrange(i...(i + 1))
}
args.removeAll { $0.hasPrefix("--") }

emit("========================================")
emit(" 鸿蒙短信 → Mac 同步")
emit("========================================")

guard let store = Store(path: DB_PATH) else { exit(1) }

if reset {
    store.exec("DELETE FROM seen_handle; DELETE FROM message; DELETE FROM sync_state;")
    emit("已清空本地记录")
}

let target = args.count > 0 ? args[0] : DEVICE_DEFAULT
var channelID: BluetoothRFCOMMChannelID = CHANNEL_DEFAULT
if args.count > 1, let v = UInt8(args[1]) { channelID = v }

guard let device = IOBluetoothDevice(addressString: target) else {
    emit("✗ 设备对象构造失败：\(target)")
    exit(1)
}

let bootstrapped = store.state("bootstrap_at") != nil
emit("设备     : \(device.name ?? "?")")
emit("通道     : \(channelID)")
emit("数据库   : \(DB_PATH)")
emit("轮询间隔 : \(Int(pollInterval)) 秒")
emit("模式     : \(once ? "只跑一轮" : "持续轮询")")
emit("事件订阅 : \(mnsEnabled ? "开启（Mac 作 MNS 服务端）" : "关闭")")
emit("基线     : \(bootstrapped ? "已建立，只处理新短信" : "未建立，本轮只记录不通知")")
emit("")

let sync = Sync(store: store, device: device, channelID: channelID, once: once)
sync.baseline = !bootstrapped

if mnsEnabled {
    emit("启动 MNS 服务端：发布 SDP 记录并监听")
    let mns = MnsServer()
    mns.start { detail in
        sync.pollNow(detail)
    }
    emit("")
}

sync.start()

CFRunLoopRun()

emit("")
emit("=== 结束 ===")
emit("已见 handle \(store.count("seen_handle")) 条，本地短信 \(store.count("message")) 条")
