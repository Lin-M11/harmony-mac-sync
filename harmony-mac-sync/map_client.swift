import Foundation
import IOBluetooth

// MAP 客户端原型：连接手机 MAS，读取短信列表与正文
// 用法: ./MAPClient <设备地址> [RFCOMM通道]

let logPath = "/tmp/map_client_result.txt"
var logBuffer = ""
try? "".write(toFile: logPath, atomically: true, encoding: .utf8)

func emit(_ items: Any...) {
    let line = items.map { String(describing: $0) }.joined(separator: " ")
    print(line)
    logBuffer += line + "\n"
    try? logBuffer.write(toFile: logPath, atomically: true, encoding: .utf8)
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// OBEX opcode
let OBEX_CONNECT: UInt8 = 0x80
let OBEX_DISCONNECT: UInt8 = 0x81
let OBEX_GET_FINAL: UInt8 = 0x83
let OBEX_SETPATH: UInt8 = 0x85

// OBEX header ID
let HDR_NAME: UInt8 = 0x01
let HDR_TYPE: UInt8 = 0x42
let HDR_TARGET: UInt8 = 0x46
let HDR_BODY: UInt8 = 0x48
let HDR_END_OF_BODY: UInt8 = 0x49
let HDR_APPPARAMS: UInt8 = 0x4C
let HDR_CONNID: UInt8 = 0xCB

// MAP Message Access Server 的 OBEX target UUID
let MAS_UUID: [UInt8] = [
    0xBB, 0x58, 0x2B, 0x40, 0x42, 0x0C, 0x11, 0xDB,
    0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
]

// 收件箱路径：OBEX 不支持路径分隔符，需逐级下钻
let FOLDER_PATH = ["telecom", "msg", "inbox"]

let LISTING_TYPE = "x-bt/MAP-msg-listing"
let MESSAGE_TYPE = "x-bt/message"

// 取前几条短信的正文
let MAX_BODIES = 3

let MAX_CHUNKS = 600
// 首次取列表时服务端可能需要较长时间准备，等待放宽
let STEP_TIMEOUT: Double = 20.0

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

// 从 XML 里取出 msg 节点属性
struct MsgInfo {
    var handle = ""
    var subject = ""
    var datetime = ""
    var senderName = ""
    var senderAddress = ""
    var isRead = ""
    var type = ""

    var brief: String {
        let who = senderName.isEmpty ? senderAddress : senderName
        return "[\(datetime)] \(who) — \(subject)"
    }
}

final class ListingParser: NSObject, XMLParserDelegate {
    var msgs: [MsgInfo] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        guard elementName == "msg" else { return }
        var m = MsgInfo()
        m.handle = attributes["handle"] ?? ""
        m.subject = attributes["subject"] ?? ""
        m.datetime = attributes["datetime"] ?? ""
        m.senderName = attributes["sender_name"] ?? ""
        m.senderAddress = attributes["sender_address"] ?? ""
        m.isRead = attributes["read"] ?? ""
        m.type = attributes["type"] ?? ""
        msgs.append(m)
    }
}

func parseListing(_ xml: String) -> [MsgInfo] {
    // 去掉 XML 声明前的杂散字节
    guard let start = xml.firstIndex(of: "<") else { return [] }
    let clean = String(xml[start...])
    let parser = XMLParser(data: Data(clean.utf8))
    let delegate = ListingParser()
    parser.delegate = delegate
    parser.parse()
    return delegate.msgs
}

final class Client: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var connectionID: [UInt8]?
    var rxBuffer: [UInt8] = []
    var token = 0
    var chunks = 0

    enum Phase { case connecting, setpath, listing, body, done }
    var phase: Phase = .connecting
    var pathIndex = 0
    var bodyIndex = 0
    var handles: [String] = []
    var acc: [UInt8] = []
    var listingXML = ""

    func withConnID(_ body: [UInt8]) -> [UInt8] {
        guard let cid = connectionID else { return body }
        return [HDR_CONNID] + cid + body
    }

    func parseHeaders(_ bytes: [UInt8]) -> [(UInt8, [UInt8])] {
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

    // MARK: - 发送

    func start(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
        emit("打开 RFCOMM 通道 \(channelID) …")
        var ch: IOBluetoothRFCOMMChannel? = nil
        let rc = device.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
        emit("  返回码 \(rc)")
        channel = ch
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == kIOReturnSuccess else {
            emit("✗ 通道打开失败 status=\(status)")
            finish()
            return
        }
        emit("✓ 通道已建立")

        // Version / Flags / MaxPacketLength（通告较大的接收包长，减少分片）
        var body: [UInt8] = [0x10, 0x00, 0xFF, 0xFF]
        body += lenHeader(HDR_TARGET, MAS_UUID)
        send(frame(opcode: OBEX_CONNECT, body: body), note: "Connect")
    }

    func sendSetPath(_ folder: String) {
        // SETPATH 不能携带 Connection ID
        var body: [UInt8] = [0x00, 0x00]
        body += lenHeader(HDR_NAME, utf16be(folder))
        send(frame(opcode: OBEX_SETPATH, body: body), note: "SETPATH \(folder)")
    }

    func sendListing() {
        var body: [UInt8] = []
        body += lenHeader(HDR_TYPE, Array(LISTING_TYPE.utf8))
        body += lenHeader(HDR_NAME, Array("inbox".utf8))
        // GET 必须携带 Connection ID
        send(frame(opcode: OBEX_GET_FINAL, body: withConnID(body)), note: "GET 短信列表")
    }

    func sendBody(_ handle: String) {
        var body: [UInt8] = []
        body += lenHeader(HDR_TYPE, Array(MESSAGE_TYPE.utf8))
        body += lenHeader(HDR_NAME, Array(handle.utf8))
        // AppParams：请求 UTF-8 字符集
        body += lenHeader(HDR_APPPARAMS, [0x14, 0x01, 0x02])
        send(frame(opcode: OBEX_GET_FINAL, body: withConnID(body)), note: "GET 正文 \(handle)")
    }

    func sendContinue() {
        send(frame(opcode: OBEX_GET_FINAL, body: withConnID([])), note: "续传")
    }

    func send(_ packet: [UInt8], note: String) {
        emit("→ \(note)（\(packet.count) 字节）")
        acc = []
        chunks = 0
        token += 1
        armTimeout()
        write(packet)
    }

    func armTimeout() {
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + STEP_TIMEOUT) {
            guard t == self.token else { return }
            emit("  ⏱ 无响应")
            self.fail("超时")
        }
    }

    func write(_ bytes: [UInt8]) {
        var buf = bytes
        let rc = channel?.writeSync(&buf, length: UInt16(buf.count))
        if rc != kIOReturnSuccess {
            emit("  ✗ 写入返回码 \(String(describing: rc))")
        }
    }

    // MARK: - 接收

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
        let headers = parseHeaders(bytes)

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
                if chunks % 20 == 0 { emit("  已接收 \(chunks) 片…") }
                token += 1
                armTimeout()
                sendContinue()
                return
            }
            emit("  ✗ 达到分片上限 \(MAX_CHUNKS)")
            fail("分片超限")
            return
        }

        if !isSuccess {
            emit("  ✗ 响应码 0x\(String(format: "%02X", op))（\(bytes.count) 字节）")
            emit("    \(hex(Array(bytes.prefix(64))))")
            fail("响应码 0x\(String(format: "%02X", op))")
            return
        }

        switch phase {
        case .connecting:
            emit("  ✓ Connect 成功")
            phase = .setpath
            pathIndex = 0
            sendSetPath(FOLDER_PATH[pathIndex])

        case .setpath:
            emit("  ✓ 进入 \(FOLDER_PATH[pathIndex])")
            pathIndex += 1
            if pathIndex < FOLDER_PATH.count {
                sendSetPath(FOLDER_PATH[pathIndex])
            } else {
                emit("  ✓ 路径就绪 \(FOLDER_PATH.joined(separator: "/"))")
                phase = .listing
                sendListing()
            }

        case .listing:
            emit("  ✓ 列表接收完成，\(acc.count) 字节（\(chunks + 1) 片）")
            listingXML = String(decoding: acc, as: UTF8.self)
            let outPath = "/tmp/map_listing.xml"
            try? Data(acc).write(to: URL(fileURLWithPath: outPath))
            emit("  原始 XML 已写入 \(outPath)")
            reportListing()
            startBodies()

        case .body:
            let handle = handles[bodyIndex]
            emit("  ✓ 正文接收完成，\(acc.count) 字节")
            let outPath = "/tmp/map_body_\(handle).txt"
            try? Data(acc).write(to: URL(fileURLWithPath: outPath))
            emit("  正文已写入 \(outPath)")
            reportBody(acc)
            bodyIndex += 1
            nextBody()

        case .done:
            finish()
        }
    }

    func reportListing() {
        let msgs = parseListing(listingXML)
        emit("")
        emit("========================================")
        emit(" 短信列表：共 \(msgs.count) 条")
        emit("========================================")
        for (i, m) in msgs.enumerated() {
            emit("\(i + 1). \(m.brief)")
            emit("     handle=\(m.handle)  已读=\(m.isRead)  类型=\(m.type)")
        }
        if msgs.isEmpty {
            emit("（收件箱为空）")
        }
        emit("")
    }

    func startBodies() {
        let msgs = parseListing(listingXML)
        handles = msgs.map { $0.handle }.filter { !$0.isEmpty }
        if handles.isEmpty {
            emit("没有可读取的正文，结束。")
            finish()
            return
        }
        bodyIndex = 0
        emit("开始读取前 \(min(MAX_BODIES, handles.count)) 条短信的正文…")
        emit("")
        nextBody()
    }

    func nextBody() {
        guard bodyIndex < handles.count && bodyIndex < MAX_BODIES else {
            emit("")
            emit("=== 全部完成 ===")
            finish()
            return
        }
        phase = .body
        sendBody(handles[bodyIndex])
    }

    func reportBody(_ data: [UInt8]) {
        let text = String(decoding: data, as: UTF8.self)
        let shown = text.count > 800 ? String(text.prefix(800)) + "\n…（截断）" : text
        emit("  正文预览：")
        emit(shown)
        emit("")
    }

    func fail(_ reason: String) {
        emit("✗ 中止：\(reason)")
        finish()
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        emit("[!] 通道已关闭")
    }

    func finish() {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

emit("========================================")
emit(" MAP 客户端原型")
emit("========================================")

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "E8-1E-92-55-2D-D4"
var channelID: BluetoothRFCOMMChannelID = 26
if CommandLine.arguments.count > 2, let v = UInt8(CommandLine.arguments[2]) {
    channelID = v
}

guard let device = IOBluetoothDevice(addressString: target) else {
    emit("✗ 设备对象构造失败: \(target)")
    exit(1)
}

emit("设备     : \(device.name ?? "?")")
emit("地址     : \(device.addressString ?? "?")")
emit("已配对   : \(device.isPaired() ? "是" : "否")")
emit("通道     : \(channelID)")
emit("")

let client = Client()
client.start(device: device, channelID: channelID)

CFRunLoopRunInMode(.defaultMode, 180.0, false)
emit("")
emit("=== 结束 ===")
