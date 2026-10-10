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
let LISTING_LIMIT_DEFAULT: UInt16 = 20   // 每次只取最新的 N 条，--limit 可改
var listingLimit: UInt16 = LISTING_LIMIT_DEFAULT
let LISTING_WIDEN_CAP: UInt16 = 200      // 窗口打满时放宽的上限
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

// MNS 的 128 位 UUID，只在自检里当样例用
let MNS_UUID_128: [UInt8] = [
    0xBB, 0x58, 0x2B, 0x41, 0x42, 0x0C, 0x11, 0xDB,
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

// MARK: - 订阅新消息事件的报文

// 规范要求的头部组合：连接标识 + 类型 + 通知状态，正文放一个填充字节。
// 空正文的 PUT 在 OBEX 里等同删除，所以这个填充字节不能省。
let NOTIF_STATUS_TAG: UInt8 = 0x0E     // 通知状态
let NOTIF_STATUS_ON: UInt8 = 0x01      // 打开
let NOTIF_BODY_FILLER: UInt8 = 0x30    // 规范规定的填充字节

// 订阅新消息事件。规范要求的头部组合是「连接标识 + 类型 + 通知状态 + 填充字节」，
// 这里额外备几种写法兜底。
let SESSION_ID_GUESS: [UInt8] = [0x00, 0x00, 0x00, 0x01]

let NOTIF_VARIANTS = [
    "ConnID + Type + 通知状态 + 填充字节",
    "无 ConnID + Type + 通知状态 + 填充字节",
    "已学到的 ConnID + Type + 通知状态 + 填充字节",
    "ConnID + Name + Type + 通知状态 + 填充字节",
    "ConnID + Type + 通知状态 + Body 填充字节",
]

func notifRequest(variant: Int, learnedConnID: [UInt8]?) -> [UInt8] {
    var body: [UInt8] = []
    if variant == 3 { body += lenHeader(HDR_NAME, Array(NOTIF_REG_TYPE.utf8)) }
    body += lenHeader(HDR_TYPE, Array(NOTIF_REG_TYPE.utf8))
    body += lenHeader(HDR_APPPARAMS, [NOTIF_STATUS_TAG, 0x01, NOTIF_STATUS_ON])
    body += lenHeader(variant == 4 ? HDR_BODY : HDR_END_OF_BODY, [NOTIF_BODY_FILLER])

    var cid: [UInt8]?
    switch variant {
    case 0, 3, 4: cid = SESSION_ID_GUESS
    case 1: cid = nil
    default: cid = learnedConnID
    }
    if let c = cid { body = [HDR_CONNID] + c + body }
    return frame(opcode: OBEX_PUT_FINAL, body: body)
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
let EVENT_REPORT_TYPE = "x-bt/map-event-report"

// 数字元素的写法。SDP 规范允许几种表达方式，本机 SDP 服务器认哪一种要靠试。
enum NumStyle: String {
    case dictSize  = "完整字典"
    case dictPlain = "简写字典"
    case typed     = "显式构造"
    case number    = "裸 NSNumber"
}

func bytesToUInt(_ b: [UInt8]) -> UInt32 {
    b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

func sdpSizeDescriptor(for count: Int) -> UInt8 {
    switch count {
    case 1: return 0
    case 2: return 1
    case 4: return 2
    case 8: return 3
    case 16: return 4
    default: return 0
    }
}

func sdpNumber(_ bytes: [UInt8], style: NumStyle) -> Any {
    switch style {
    case .dictSize:
        return ["DataElementType": 1, "DataElementSize": bytes.count,
                "DataElementValue": Data(bytes)] as [String: Any]
    case .dictPlain:
        return ["DataElementType": 1, "DataElementValue": Data(bytes)] as [String: Any]
    case .typed:
        if let e = IOBluetoothSDPDataElement.withType(
            1, sizeDescriptor: sdpSizeDescriptor(for: bytes.count),
            size: UInt32(bytes.count), value: NSNumber(value: bytesToUInt(bytes))) {
            return e
        }
        return Data(bytes)
    case .number:
        return NSNumber(value: bytesToUInt(bytes))
    }
}

// 协议栈的写法。本机 SDP 服务器对「数组套数组」的接受程度不确定，两种都备着。
enum PdlStyle: String {
    case nestedDict = "嵌套数组"
    case uuidOnly = "仅 UUID"
}

func mnsServiceDict(channel: UInt8, num: NumStyle, style: PdlStyle,
                    includeProfile: Bool = true, name: String = "MAP MNS") -> [String: Any] {
    let l2capU = IOBluetoothSDPUUID(uuid16: L2CAP_UUID16)!
    let rfcommU = IOBluetoothSDPUUID(uuid16: RFCOMM_UUID16)!
    let obexU = IOBluetoothSDPUUID(uuid16: OBEX_UUID16)!

    var dict: [String: Any] = [
        "0001 ServiceClassIDList": [IOBluetoothSDPUUID(uuid16: MNS_UUID16)!],
        "0005 BrowseGroupList": [IOBluetoothSDPUUID(uuid16: BROWSE_GROUP_UUID16)!],
        "0100 ServiceName": name,
        // 低两位：Notification Registration + Notification
        "0317 SupportedFeatures": sdpNumber([0x00, 0x00, 0x00, 0x03], style: num),
    ]

    switch style {
    case .nestedDict:
        dict["0004 ProtocolDescriptorList"] = [
            [l2capU, sdpNumber([0x00, 0x03], style: num)],
            [rfcommU, sdpNumber([channel], style: num)],
            [obexU],
        ] as [Any]
    case .uuidOnly:
        dict["0004 ProtocolDescriptorList"] = [[l2capU], [rfcommU], [obexU]] as [Any]
    }

    if includeProfile {
        dict["0009 BluetoothProfileDescriptorList"] = [
            [IOBluetoothSDPUUID(uuid16: MAP_PROFILE_UUID16)!, sdpNumber([0x01, 0x02], style: num)]
        ] as [Any]
    }
    return dict
}

// 读回记录里实际存在的属性 ID，用来判断发布有没有丢东西
func sdpAttrIDs(_ rec: IOBluetoothSDPServiceRecord) -> String {
    let a = rec.attributes ?? [:]
    var out: [String] = []
    for k in a.keys {
        if let n = k as? NSNumber { out.append(String(format: "%04X", n.uint16Value)) }
    }
    return out.sorted().joined(separator: ",")
}

// 从事件报告正文里取 <event .../> 的属性。
// 手机生成的 XML 不保证把正文里的引号转义，所以按属性名扫描，不交给 XMLParser。
func parseEventReport(_ xml: String) -> String {
    guard let start = xml.range(of: "<event") else { return "" }
    let rest = xml[start.upperBound...]
    let end = rest.range(of: ">")?.lowerBound ?? rest.endIndex
    let tag = String(rest[..<end])

    func attr(_ name: String) -> String? {
        for quote in ["\"", "'"] {
            // 前面锚一个空格，避免 msg_type 被当成 type、old_folder 被当成 folder
            let needle = " " + name + "=" + quote
            guard let r = tag.range(of: needle) else { continue }
            let tail = tag[r.upperBound...]
            guard let close = tail.range(of: quote) else { continue }
            return String(tail[..<close.lowerBound])
        }
        return nil
    }

    var parts = ["type=\(attr("type") ?? "?")"]
    if let h = attr("handle") { parts.append("handle=\(h)") }
    if let f = attr("folder") { parts.append("folder=\(f)") }
    if let m = attr("msg_type") { parts.append("msg_type=\(m)") }
    return parts.joined(separator: " ")
}

// MNS 侧对一包报文的判定结果。抽成纯逻辑，就能脱开蓝牙用合成报文自检。
struct MnsDecision {
    var code: UInt8
    var lines: [String]
    var event: String?
    var close = false
}

func mnsDecide(_ packet: [UInt8], connID: inout [UInt8]) -> MnsDecision {
    guard let op = packet.first else { return MnsDecision(code: 0xA0, lines: []) }
    let headers = parseObexHeaders(packet)
    let type = headers.first { $0.0 == HDR_TYPE }.map { String(decoding: $0.1, as: UTF8.self) } ?? ""
    var body: [UInt8] = []
    for (id, v) in headers where id == HDR_BODY || id == HDR_END_OF_BODY { body += v }
    var appParams: [UInt8] = []
    for (id, v) in headers where id == HDR_APPPARAMS { appParams += v }

    switch op & 0x7F {
    case 0x00:
        // 手机若在 Connect 里给了会话号，后面就用它的
        if let v = headers.first(where: { $0.0 == HDR_CONNID })?.1 { connID = v }
        return MnsDecision(code: 0xA0, lines: ["← CONNECT（\(packet.count) 字节）  会话号 \(hex(connID))"])

    case 0x02:
        if type.lowercased().contains("map-event-report") {
            let report = parseEventReport(String(decoding: body, as: UTF8.self))
            var detail = report.isEmpty ? "（正文 \(body.count) 字节）" : report
            if let masID = appParam(appParams, tag: 0x0F) { detail += "  MAS实例=\(masID)" }
            return MnsDecision(code: 0xA0, lines: ["★ 事件报告：\(detail)"], event: detail)
        }
        return MnsDecision(code: 0xA0,
                           lines: ["← PUT  Type=\(type.isEmpty ? "?" : type)  Body \(body.count) 字节"])

    case 0x01:
        return MnsDecision(code: 0xA0, lines: ["← DISCONNECT"], close: true)

    default:
        return MnsDecision(code: 0xA0, lines: ["← 未知操作 0x\(String(format: "%02X", op))"])
    }
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
        let d = mnsDecide(packet, connID: &connID)
        for line in d.lines { emit("  [MNS] \(line)") }
        respond(d.code)
        if let e = d.event { onEvent(e) }
        if d.close { _ = channel.close() }
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
    var notifications: [IOBluetoothUserNotification] = []
    var channels: [MnsChannel] = []
    var onEvent: (String) -> Void = { _ in }
    var channelID: BluetoothRFCOMMChannelID = 0
    var ignoreChannelID: BluetoothRFCOMMChannelID = 0
    var handledIDs: Set<BluetoothRFCOMMChannelID> = []
    var incomingCount = 0

    // 候选写法：数字元素的表达方式 × 协议栈的表达方式。
    // 数字元素只用本机 SDP 服务器接受得了的两类：完整字典、简写字典。
    let CANDIDATES: [(NumStyle, PdlStyle, Bool)] = [
        (.dictSize, .nestedDict, true),
        (.dictPlain, .nestedDict, true),
        (.dictSize, .nestedDict, false),
        (.dictPlain, .nestedDict, false),
    ]

    func start(onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent

        var fallback: IOBluetoothSDPServiceRecord?
        for (index, cand) in CANDIDATES.enumerated() {
            let label = "写法 \(index + 1)（\(cand.0.rawValue) + \(cand.1.rawValue)\(cand.2 ? " + Profile" : "")）"
            let dict = mnsServiceDict(channel: MNS_RFCOMM_CHANNEL, num: cand.0,
                                      style: cand.1, includeProfile: cand.2)
            guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
                emit("  [MNS] \(label) 发布返回空")
                continue
            }
            // 发布是异步的，先让它落定再读回
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))

            var cid: BluetoothRFCOMMChannelID = 0
            let ok = rec.getRFCOMMChannelID(&cid) == kIOReturnSuccess
            let hasPDL = rec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0004)) != nil
            emit("  [MNS] \(label) 属性 [\(sdpAttrIDs(rec))]  协议栈 \(hasPDL ? "有" : "没有")  通道 \(ok ? String(cid) : "读不到")")

            if ok {
                record = rec
                channelID = cid
                emit("  [MNS] ✓ 采用\(label)，RFCOMM 通道 \(cid)")
                break
            }
            // 读不出通道号：留第一份当保底，其余撤掉，免得同一个通道挂多条记录
            if fallback == nil {
                fallback = rec
            } else {
                _ = rec.remove()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        if record == nil { record = fallback }

        guard record != nil else {
            emit("  [MNS] ✗ 本机 SDP 服务器没接受这 \(CANDIDATES.count) 种候选写法")
            return
        }

        // 通道号读得到就按通道号监听；再叠一层「所有入站通道」，防通道号对不上
        if let n = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(incoming(_:channel:)),
            withChannelID: channelID,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming) {
            notifications.append(n)
        }
        if let n = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(incoming(_:channel:))) {
            notifications.append(n)
        }

        if notifications.isEmpty {
            emit("  [MNS] ✗ 入站监听注册失败")
        } else {
            let scope = channelID == 0 ? "所有入站通道" : "通道 \(channelID) 及所有入站通道"
            emit("  [MNS] 已监听\(scope)，等手机回连")
        }
    }

    @objc func incoming(_ note: IOBluetoothUserNotification!, channel: IOBluetoothRFCOMMChannel!) {
        guard let ch = channel else { return }
        let id = ch.getID()
        // 别把我们自己连手机 MAS 的那条通道当成回连
        guard id != ignoreChannelID else { return }
        guard !handledIDs.contains(id) else { return }
        handledIDs.insert(id)
        incomingCount += 1
        emit("")
        emit("  [MNS] 有设备连进来了（通道 \(id)）")
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
    var widened = false
    var baseline = false
    var pollCount = 0
    var notifVariant = 0
    var notifSupported: Bool? = nil           // nil = 还没试出来
    var awaiting = false
    var pendingPoll: DispatchWorkItem?
    var immediatePollPending = false

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
        widened = false
        immediatePollPending = false

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

    func sendNotifRegistration() {
        let packet = notifRequest(variant: notifVariant, learnedConnID: connectionID)
        send(packet, note: "订阅新消息事件［\(NOTIF_VARIANTS[notifVariant])］")
    }

    func sendListing(limit: UInt16? = nil) {
        let n = limit ?? listingLimit
        var body: [UInt8] = []
        body += lenHeader(HDR_TYPE, Array(LISTING_TYPE.utf8))
        body += lenHeader(HDR_NAME, Array("inbox".utf8))
        // MaxListCount：只要最新的 N 条。服务端不认时下面会退回不带这个参数的写法。
        let limited = listingParamsSupported != false
        if limited {
            let ap: [UInt8] = [0x01, 0x02, UInt8(n >> 8), UInt8(n & 0xFF)]
            body += lenHeader(HDR_APPPARAMS, ap)
        }
        let note = limited ? "GET 收件箱列表（最新 \(n) 条）" : "GET 收件箱列表（不带条数限制）"
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
            emit("    \(hex(Array(bytes.prefix(64))))")

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
                emit("  ↻ 该请求形式被拒，改为不带条数限制")
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

        var fresh: [Sms] = []
        for m in msgs where !store.isSeen(m.handle) {
            fresh.append(m)
        }

        // 首次接触：整窗全新，而本地记下的 handle 还没窗口多。
        // 这种时候窗口外多半还压着一大堆更早的短信，逐条弹通知就成了刷屏。
        // 把这一窗记成基线（只记 handle，不通知），之后只处理真正的新短信。
        let seenCount = store.count("seen_handle")
        if fresh.count == msgs.count && (baseline || seenCount < msgs.count) {
            for m in msgs { store.remember(m.handle, stamp: m.datetime) }
            store.setState("bootstrap_at", String(Int(Date().timeIntervalSince1970)))
            baseline = false
            store.prune(cutoffStamp(days: 120))
            emit("  ✓ 已建立基线：\(msgs.count) 条记入已见，不通知")
            emit("  已见 handle 共 \(store.count("seen_handle")) 条")
            scheduleNextPoll()
            return
        }

        // 整窗全新、且本地基线不比窗口小：窗口可能不够宽，换一个更宽的再取一次。
        // 一轮只放宽一次，下一轮回到正常窗口。不走「取整份列表」——整份要过一百多个分片，要好几分钟。
        if !widened && listingParamsSupported != false
            && msgs.count >= Int(listingLimit) && fresh.count == msgs.count {
            widened = true
            let wide = min(listingLimit * 8, LISTING_WIDEN_CAP)
            emit("  整窗全新，窗口放宽到 \(wide) 条再取一次")
            sendListing(limit: wide)
            return
        }
        widened = false

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
        var delay = pollInterval
        if immediatePollPending {
            immediatePollPending = false
            delay = 0.5
            emit("  事件曾在这一轮请求进行中到达，0.5 秒后补拉一次")
        } else {
            emit("  下次轮询 \(Int(pollInterval)) 秒后")
        }
        let item = DispatchWorkItem {
            guard self.channel != nil else { self.openSession(); return }
            self.phase = .listing
            self.sendListing()
        }
        pendingPoll = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // 手机推来事件时立刻拉一次，不等下一个轮询周期
    func pollNow(_ reason: String) {
        guard !once else { return }
        guard channel != nil else { return }
        // 有请求在路上时先记下来，等它跑完立刻补一次，而不是丢掉这次事件
        guard !awaiting, phase == .listing else {
            immediatePollPending = true
            emit("  [MNS] 事件已到（\(reason)），当前是 \(phase) 阶段，跑完立刻补一次")
            return
        }
        pendingPoll?.cancel()
        pendingPoll = nil
        emit("  [MNS] 事件触发（\(reason)），立即拉一次列表")
        phase = .listing
        sendListing()
    }

    // 心跳。轮询是静默的，卡住的时候光看日志分不出「在等」还是「已经不动了」。
    func heartbeat() {
        let link: String
        if channel == nil { link = "未开通道" }
        else if awaiting { link = "请求在途" }
        else { link = "通道已开" }
        let sub: String
        if !mnsEnabled { sub = "未启用" }
        else if notifSupported == nil { sub = "未试" }
        else { sub = notifSupported! ? "已接受" : "被拒" }
        emit("  · 心跳：\(link)，阶段 \(phase)，已轮询 \(pollCount) 次，事件订阅 \(sub)")
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

// 本地自检：拿一份事件报告正文验解析，不碰蓝牙
if let i = args.firstIndex(of: "--event"), i + 1 < args.count {
    let path = args[i + 1]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("读不到 \(path)")
        exit(1)
    }
    print("正文 \(text.count) 字")
    print("解析结果：\(parseEventReport(text))")
    exit(0)
}

// 本地自检：打印五种订阅写法的报文，不碰蓝牙
if args.contains("--dump-notif") {
    let learned: [UInt8] = [0x00, 0x00, 0x00, 0x07]
    for (i, label) in NOTIF_VARIANTS.enumerated() {
        let p = notifRequest(variant: i, learnedConnID: learned)
        print("\(i) \(label)（\(p.count) 字节）")
        print("   \(hex(p))")
    }
    exit(0)
}

// 本地自检：用合成报文走一遍 MNS 入站处理，不碰蓝牙
if args.contains("--mns-selftest") {
    var connID: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    // 手机连上 MNS 时发的 Connect（带 Target = MNS UUID）
    var c1: [UInt8] = [0x10, 0x00, 0xFF, 0xFF]
    c1 += lenHeader(HDR_TARGET, MNS_UUID_128)
    let connect = frame(opcode: 0x80, body: c1)

    // 手机推来的事件报告
    let report = """
    <?xml version="1.0" encoding="UTF-8"?>
    <MAP-event-report version="1.0">
    <event type="NewMessage" handle="0000000000000042" folder="telecom/msg/inbox" msg_type="SMS_GSM"/>
    </MAP-event-report>
    """
    var c2: [UInt8] = []
    c2 += lenHeader(HDR_TYPE, Array(EVENT_REPORT_TYPE.utf8))
    c2 += lenHeader(HDR_APPPARAMS, [0x0F, 0x01, 0x01])
    c2 += lenHeader(HDR_END_OF_BODY, Array(report.utf8))
    let eventPut = frame(opcode: OBEX_PUT_FINAL, body: c2)

    // 手机断开
    let disconnect = frame(opcode: 0x81, body: [])

    for (label, packet) in [("Connect", connect), ("事件报告", eventPut), ("断开", disconnect)] {
        let d = mnsDecide(packet, connID: &connID)
        print("== \(label)（\(packet.count) 字节）")
        print("   应答 \(String(format: "0x%02X", d.code))   会话号 \(hex(connID))\(d.close ? "   关闭通道" : "")")
        for l in d.lines { print("   \(l)") }
        if let e = d.event { print("   → 触发同步：\(e)") }
    }
    exit(0)
}

// 本地自检：把几种候选字典按 plist 打出来，不碰蓝牙
if args.contains("--dump-sdp") {
    let candidates: [(NumStyle, PdlStyle, Bool)] = [
        (.dictSize, .nestedDict, true),
        (.typed, .nestedDict, true),
        (.number, .nestedDict, true),
        (.dictPlain, .nestedDict, true),
        (.dictSize, .nestedDict, false),
    ]
    for (i, c) in candidates.enumerated() {
        print("===== 候选 \(i + 1)：\(c.0.rawValue) + \(c.1.rawValue)\(c.2 ? " + Profile" : "") =====")
        let dict = mnsServiceDict(channel: MNS_RFCOMM_CHANNEL, num: c.0, style: c.1, includeProfile: c.2)
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("（打不出来）")
        }
    }
    exit(0)
}

// 只跑 MNS 服务端：发布 SDP 记录并守着，看手机能不能主动连过来。不碰 MAP 会话。
if let i = args.firstIndex(of: "--mns-hold") {
    let secs = i + 1 < args.count ? (Double(args[i + 1]) ?? 150) : 150
    print("只跑 MNS 服务端，保持 \(Int(secs)) 秒")
    print("")

    let mns = MnsServer()
    mns.start { detail in
        print("  [MNS] 事件：\(detail)")
    }
    print("")

    var left = secs
    let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
        left -= 15
        print("  · 还剩 \(Int(max(left, 0))) 秒，入站连接 \(mns.incomingCount) 次")
    }
    RunLoop.current.add(timer, forMode: .default)
    RunLoop.current.run(until: Date().addingTimeInterval(secs))
    print("")
    print("结束：入站连接共 \(mns.incomingCount) 次")
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
if let i = args.firstIndex(of: "--limit"), i + 1 < args.count,
   let v = UInt16(args[i + 1]), v >= 1 {
    listingLimit = v
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
emit("每轮条数 : \(listingLimit) 条")
emit("模式     : \(once ? "只跑一轮" : "持续轮询")")
emit("事件订阅 : \(mnsEnabled ? "开启（Mac 作 MNS 服务端）" : "关闭")")
emit("基线     : \(bootstrapped ? "已建立，只处理新短信" : "未建立，本轮只记录不通知")")
emit("")

let sync = Sync(store: store, device: device, channelID: channelID, once: once)
sync.baseline = !bootstrapped

if mnsEnabled {
    emit("启动 MNS 服务端：发布 SDP 记录并监听")
    let mns = MnsServer()
    mns.ignoreChannelID = channelID
    mns.start { detail in
        sync.pollNow(detail)
    }
    emit("")
}

sync.start()

// 心跳：每 10 秒报一次状态，卡住的时候也能从日志里看出来
if !once {
    let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        sync.heartbeat()
    }
    RunLoop.current.add(timer, forMode: .default)
}

CFRunLoopRun()

emit("")
emit("=== 结束 ===")
emit("已见 handle \(store.count("seen_handle")) 条，本地短信 \(store.count("message")) 条")
