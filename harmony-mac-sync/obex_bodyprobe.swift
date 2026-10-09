import Foundation
import IOBluetooth

// 正文请求探测：每个用例独立开一条 OBEX 会话，一次只变一个因素。
// 先取一次列表拿到有效 handle，再依次用不同编码/头组合请求正文。
// 用法: ./OBEXBodyProbe <设备地址> [RFCOMM通道]

let logPath = "/tmp/obex_bodyprobe_result.txt"
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

func hexShort(_ bytes: [UInt8]) -> String {
    let head = bytes.prefix(56).map { String(format: "%02X", $0) }.joined(separator: " ")
    return bytes.count > 56 ? head + " …(共 \(bytes.count))" : head
}

// OBEX opcode。高位是 final 位：请求只有一个包时必须置位。
let OBEX_CONNECT: UInt8 = 0x80
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

let MAS_UUID: [UInt8] = [
    0xBB, 0x58, 0x2B, 0x40, 0x42, 0x0C, 0x11, 0xDB,
    0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
]

let FOLDER_PATH = ["telecom", "msg", "inbox"]
let LISTING_TYPE = "x-bt/MAP-msg-listing"
let MESSAGE_TYPE = "x-bt/message"

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

func setpathPacket(_ folder: String) -> [UInt8] {
    // SETPATH 不携带 Connection ID
    var body: [UInt8] = [0x00, 0x00]
    body += lenHeader(HDR_NAME, utf16be(folder))
    return frame(opcode: OBEX_SETPATH, body: body)
}

func listingPacket(_ cid: [UInt8]?) -> [UInt8] {
    var body: [UInt8] = []
    body += lenHeader(HDR_TYPE, Array(LISTING_TYPE.utf8))
    body += lenHeader(HDR_NAME, Array("inbox".utf8))
    if let c = cid { body = [HDR_CONNID] + c + body }
    return frame(opcode: OBEX_GET_FINAL, body: body)
}

// handle 放进 Name 头的几种写法
enum NameEnc: String {
    case utf8Hex     = "UTF-8 十六进制字符串"
    case utf16Hex    = "UTF-16BE 十六进制字符串"
    case utf16HexNul = "UTF-16BE 十六进制字符串 + 0x0000"
    case raw8        = "8 字节大端原始值"
    case utf8Dec     = "UTF-8 十进制字符串"
    case utf16DecNul = "UTF-16BE 十进制字符串 + 0x0000"
    case utf8Hex0x   = "UTF-8 十六进制字符串带 0x 前缀"
}

func encodeHandle(_ enc: NameEnc, _ handle: String) -> [UInt8] {
    let value = UInt64(handle, radix: 16) ?? 0
    switch enc {
    case .utf8Hex:     return Array(handle.utf8)
    case .utf16Hex:    return utf16be(handle)
    case .utf16HexNul: return utf16be(handle) + [0x00, 0x00]
    case .raw8:
        return (0..<8).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xFF) }
    case .utf8Dec:     return Array(String(value).utf8)
    case .utf16DecNul: return utf16be(String(value)) + [0x00, 0x00]
    case .utf8Hex0x:   return Array(("0x" + handle).utf8)
    }
}

struct BodyCase {
    let label: String
    let enc: NameEnc
    let useType: Bool
    let charset: UInt8?
    let attachment: UInt8?
    let useConn: Bool
}

let cases: [BodyCase] = [
    BodyCase(label: "十六进制串按 UTF-8 直接写", enc: .utf8Hex,
             useType: true, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "十六进制串按 UTF-16BE + 0x0000", enc: .utf16HexNul,
             useType: true, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "十六进制串按 UTF-16BE，无结尾", enc: .utf16Hex,
             useType: true, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "UTF-16BE + 0x0000，头部为 Type 与 Name", enc: .utf16HexNul,
             useType: true, charset: nil, attachment: nil, useConn: true),
    BodyCase(label: "UTF-16BE + 0x0000，头部为 Name 与 AppParams", enc: .utf16HexNul,
             useType: false, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "UTF-16BE + 0x0000，AppParams 只带 Charset", enc: .utf16HexNul,
             useType: true, charset: 0x01, attachment: nil, useConn: true),
    BodyCase(label: "8 字节大端原始值", enc: .raw8,
             useType: true, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "十进制字符串按 UTF-8", enc: .utf8Dec,
             useType: true, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "UTF-16BE + 0x0000，头部不含 Connection ID", enc: .utf16HexNul,
             useType: true, charset: 0x01, attachment: 0x00, useConn: false),
    BodyCase(label: "UTF-8 十六进制串，AppParams 只带 Charset", enc: .utf8Hex,
             useType: true, charset: 0x01, attachment: nil, useConn: true),
    BodyCase(label: "UTF-16BE + 0x0000，Charset 取 0x02", enc: .utf16HexNul,
             useType: true, charset: 0x02, attachment: 0x00, useConn: true),
    BodyCase(label: "UTF-16BE + 0x0000，AppParams 只带 Attachment", enc: .utf16HexNul,
             useType: true, charset: nil, attachment: 0x00, useConn: true),
    BodyCase(label: "十进制字符串按 UTF-16BE + 0x0000", enc: .utf16DecNul,
             useType: true, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "十六进制串带 0x 前缀按 UTF-8", enc: .utf8Hex0x,
             useType: true, charset: 0x01, attachment: 0x00, useConn: true),
    BodyCase(label: "UTF-16BE + 0x0000，Attachment 取 0x01", enc: .utf16HexNul,
             useType: true, charset: 0x01, attachment: 0x01, useConn: true),
]

let STEP_TIMEOUT: Double = 8.0
let PACE_DELAY: Double = 0.15
let MAX_CHUNKS = 12

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var device: IOBluetoothDevice?
    var channelID: BluetoothRFCOMMChannelID = 26
    var connectionID: [UInt8]?
    var rxBuffer: [UInt8] = []
    var token = 0

    enum Mode { case prep, cases }
    var mode: Mode = .prep

    var pending: [[UInt8]] = []
    var reqIdx = 0
    var chunks = 0
    var acc: [UInt8] = []
    var listingDone = false

    var caseIdx = -1
    var handle = ""
    var results: [(String, String)] = []

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

    func start(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
        self.device = device
        self.channelID = channelID
        openSession()
    }

    // MARK: - 会话管理

    func openSession() {
        connectionID = nil
        rxBuffer.removeAll()
        pending = []
        reqIdx = 0
        chunks = 0
        acc = []

        if let ch = channel { _ = ch.close() }
        channel = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let dev = self.device else { self.finish(); return }
            var ch: IOBluetoothRFCOMMChannel? = nil
            let rc = dev.openRFCOMMChannelAsync(&ch, withChannelID: self.channelID, delegate: self)
            if rc != kIOReturnSuccess { emit("    ✗ 打开通道返回码 \(rc)") }
            self.channel = ch
        }
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == kIOReturnSuccess else {
            emit("    ✗ 通道打开失败 status=\(status)")
            if mode == .prep { finish() } else { nextCase() }
            return
        }
        var body: [UInt8] = [0x10, 0x00, 0xFF, 0xFF]
        body += lenHeader(HDR_TARGET, MAS_UUID)
        let pkt = frame(opcode: OBEX_CONNECT, body: body)
        send(pkt)
    }

    func send(_ packet: [UInt8]) {
        token += 1
        armTimeout()
        DispatchQueue.main.asyncAfter(deadline: .now() + PACE_DELAY) { self.write(packet) }
    }

    func armTimeout() {
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + STEP_TIMEOUT) {
            guard t == self.token else { return }
            emit("    ⏱ 无响应")
            if self.pending.isEmpty {
                if self.mode == .prep { self.finish() } else { self.nextCase() }
            } else {
                self.record("超时无响应")
                self.advance()
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        var buf = bytes
        let rc = channel?.writeSync(&buf, length: UInt16(buf.count))
        if rc != kIOReturnSuccess {
            emit("    ✗ 写入返回码 \(String(describing: rc))")
        }
    }

    func record(_ code: String) {
        let label: String
        if mode == .prep {
            label = "准备 · 第\(reqIdx + 1)步"
        } else {
            label = "用例\(caseIdx + 1) \(cases[caseIdx].label)"
        }
        results.append((label, code))
    }

    func advance() {
        reqIdx += 1
        chunks = 0
        sendNextReq()
    }

    func sendNextReq() {
        guard reqIdx < pending.count else {
            if mode == .prep { startCases() } else { nextCase() }
            return
        }
        let pkt = pending[reqIdx]
        emit("    [\(reqIdx + 1)/\(pending.count)] → \(hex(pkt))")
        send(pkt)
    }

    // MARK: - 准备阶段

    func startCases() {
        if handle.isEmpty {
            // 准备阶段没拿到 handle 时，退回上次保存的列表
            if let saved = try? String(contentsOfFile: "/tmp/map_listing.xml", encoding: .utf8),
               let h = firstHandle(saved) {
                handle = h
                emit("")
                emit("（本轮未取到列表，沿用上次保存的 handle \(handle)）")
            }
        }
        guard !handle.isEmpty else {
            emit("✗ 没有可用的 handle，结束")
            finish()
            return
        }
        mode = .cases
        caseIdx = -1
        nextCase()
    }

    func nextCase() {
        caseIdx += 1
        guard caseIdx < cases.count else {
            summary()
            finish()
            return
        }
        emit("")
        emit("========================================")
        emit(" 用例 \(caseIdx + 1)/\(cases.count)：\(cases[caseIdx].label)")
        emit("========================================")
        openSession()
    }

    // MARK: - 接收

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        rxBuffer += Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))

        while rxBuffer.count >= 3 {
            let len = Int(rxBuffer[1]) << 8 | Int(rxBuffer[2])
            guard len >= 3 else {
                emit("    ✗ 报文长度异常 \(len)，丢弃缓冲")
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
        let tag = isSuccess ? "成功" : (isContinue ? "继续" : "拒绝")
        emit("    ← \(bytes.count) 字节  0x\(String(format: "%02X", op)) \(tag)")
        emit("      \(hexShort(bytes))")

        let headers = parseHeaders(bytes)

        for (id, value) in headers where id == HDR_CONNID {
            if connectionID == nil {
                connectionID = value
                emit("      ↳ Connection ID = \(hex(value))")
            }
        }

        for (id, value) in headers where id == HDR_BODY || id == HDR_END_OF_BODY {
            acc += value
        }

        // pending 为空 = Connect 的响应
        if pending.isEmpty {
            guard isSuccess else {
                emit("      ✗ Connect 未成功")
                if mode == .prep { finish() } else { nextCase() }
                return
            }
            var list: [[UInt8]] = FOLDER_PATH.map { setpathPacket($0) }
            if mode == .prep {
                list.append(listingPacket(connectionID))
            } else {
                list.append(casePacket(cases[caseIdx]))
            }
            pending = list
            reqIdx = 0
            sendNextReq()
            return
        }

        if isContinue {
            chunks += 1
            if chunks <= MAX_CHUNKS {
                if chunks % 4 == 0 { emit("      （续传 \(chunks)，累计 \(acc.count) 字节）") }
                token += 1
                armTimeout()
                var cont: [UInt8] = []
                if let cid = connectionID { cont = [HDR_CONNID] + cid }
                write(frame(opcode: OBEX_GET_FINAL, body: cont))
                return
            }
            emit("      ✗ 达到续传上限")
            record("0x90 ×\(chunks) 后放弃")
            advance()
            return
        }

        record("0x\(String(format: "%02X", op)) \(tag)")

        if mode == .prep && !listingDone && reqIdx == pending.count - 1 {
            listingDone = true
            let text = String(decoding: acc, as: UTF8.self)
            emit("      ✓ 列表 \(acc.count) 字节")
            if let h = firstHandle(text) {
                handle = h
                emit("      ✓ 取到 handle \(handle)")
            } else {
                emit("      ✗ 未能从列表里取到 handle")
            }
        }

        if !acc.isEmpty && !isSuccess {
            emit("      Body \(acc.count) 字节：\(String(decoding: acc.prefix(400), as: UTF8.self))")
        }

        if isSuccess && mode == .cases {
            let text = String(decoding: acc, as: UTF8.self)
            let shown = text.count > 2000 ? String(text.prefix(2000)) + "\n…（截断）" : text
            emit("      ✓ 正文 \(acc.count) 字节：")
            emit(shown)
            try? Data(acc).write(to: URL(fileURLWithPath: "/tmp/map_body_probe.txt"))
            emit("      ✓ 已写入 /tmp/map_body_probe.txt")
        }

        advance()
    }

    func casePacket(_ c: BodyCase) -> [UInt8] {
        var body: [UInt8] = []
        if c.useType { body += lenHeader(HDR_TYPE, Array(MESSAGE_TYPE.utf8)) }
        body += lenHeader(HDR_NAME, encodeHandle(c.enc, handle))
        var app: [UInt8] = []
        if let cs = c.charset { app += [0x14, 0x01, cs] }
        if let at = c.attachment { app += [0x01, 0x01, at] }
        if !app.isEmpty { body += lenHeader(HDR_APPPARAMS, app) }
        if c.useConn, let cid = connectionID { body = [HDR_CONNID] + cid + body }
        return frame(opcode: OBEX_GET_FINAL, body: body)
    }

    func firstHandle(_ text: String) -> String? {
        guard let r = text.range(of: "handle=\"") else { return nil }
        let rest = text[r.upperBound...]
        let digits = rest.prefix { $0.isHexDigit }
        return digits.isEmpty ? nil : String(digits)
    }

    func summary() {
        emit("")
        emit("========================================")
        emit(" 结果汇总")
        emit("========================================")
        for (label, code) in results {
            emit("\(code)  ←  \(label)")
        }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        // 主动切换用例时会关闭通道，这里不额外处理
    }

    func finish() {
        emit("")
        emit("=== 结束 ===")
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

emit("========================================")
emit(" MAP 正文请求探测（每用例独立会话）")
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
emit("用例数   : \(cases.count)")

let probe = Probe()
probe.start(device: device, channelID: channelID)

CFRunLoopRunInMode(.defaultMode, 300.0, false)
