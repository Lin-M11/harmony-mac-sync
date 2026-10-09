import Foundation
import IOBluetooth

// MAP 路径探测：在一条 OBEX 会话上依次尝试多种 SETPATH / GET 写法，
// 打印每一步的原始响应，用来定位服务端到底接受哪种形式。
// 用法: ./OBEXPathProbe <设备地址> [RFCOMM通道]

let logPath = "/tmp/obex_pathprobe_result.txt"
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
    let head = bytes.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
    return bytes.count > 48 ? head + " …(共 \(bytes.count))" : head
}

// OBEX opcode
let OBEX_CONNECT: UInt8 = 0x80
let OBEX_GET: UInt8 = 0x03
let OBEX_SETPATH: UInt8 = 0x85

// OBEX header ID
let HDR_NAME: UInt8 = 0x01
let HDR_TYPE: UInt8 = 0x42
let HDR_TARGET: UInt8 = 0x46
let HDR_BODY: UInt8 = 0x48
let HDR_END_OF_BODY: UInt8 = 0x49
let HDR_CONNID: UInt8 = 0xCB

let MAS_UUID: [UInt8] = [
    0xBB, 0x58, 0x2B, 0x40, 0x42, 0x0C, 0x11, 0xDB,
    0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
]

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

// 单步等待响应的上限
let STEP_TIMEOUT: Double = 3.0

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var connectionID: [UInt8]?
    var queue: [(String, [UInt8])] = []
    var idx = 0
    var rxBuffer: [UInt8] = []
    var token = 0
    var bodyBytes: [UInt8] = []
    var connected = false

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

    func open(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
        emit("[1] 打开 RFCOMM 通道 \(channelID)")
        var ch: IOBluetoothRFCOMMChannel? = nil
        let rc = device.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
        emit("    返回码 \(rc)")
        channel = ch
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        emit("[2] 通道打开完成，status = \(status)")
        guard status == kIOReturnSuccess else {
            emit("    ✗ 通道打开失败")
            finish()
            return
        }
        emit("    ✓ 通道已建立")
        emit("")
        var body: [UInt8] = [0x10, 0x00, 0x02, 0x00]
        body += lenHeader(HDR_TARGET, MAS_UUID)
        emit("[3] OBEX Connect")
        emit("    → \(hex(frame(opcode: OBEX_CONNECT, body: body)))")
        token += 1
        armTimeout()
        write(frame(opcode: OBEX_CONNECT, body: body))
    }

    // 超时保护：某步没有响应就跳到下一步
    func armTimeout() {
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + STEP_TIMEOUT) {
            guard t == self.token else { return }
            emit("    ⏱ \(STEP_TIMEOUT) 秒无响应，跳过")
            self.sendNext()
        }
    }

    func buildQueue() {
        guard let cid = connectionID else { return }

        func conn(_ b: [UInt8]) -> [UInt8] { [HDR_CONNID] + cid + b }

        func setpath(_ folder: String, nullTerm: Bool, conn: Bool, target: Bool,
                     utf8: Bool = false, flags: UInt8 = 0x00) -> [UInt8] {
            var name = utf8 ? Array(folder.utf8) : utf16be(folder)
            if nullTerm { name += [0x00, 0x00] }
            var body: [UInt8] = [flags, 0x00]
            body += lenHeader(HDR_NAME, name)
            if target { body += lenHeader(HDR_TARGET, MAS_UUID) }
            return frame(opcode: OBEX_SETPATH, body: conn ? withConnID(body) : body)
        }

        func get(_ type: String?, name: String?) -> [UInt8] {
            var body: [UInt8] = []
            if let t = type { body += lenHeader(HDR_TYPE, Array(t.utf8)) }
            if let n = name { body += lenHeader(HDR_NAME, Array(n.utf8)) }
            return frame(opcode: OBEX_GET, body: withConnID(body))
        }

        func root() -> [UInt8] {
            // Flags=0x01 退回上级，无 Name
            frame(opcode: OBEX_SETPATH, body: withConnID([0x01, 0x00]))
        }

        queue = [
            ("GET x-obex/folder-listing（无 Name）—— 看根目录结构", get("x-obex/folder-listing", name: nil)),

            ("SETPATH 退回根（Flags=0x01）", root()),
            ("SETPATH telecom（UTF-16BE 无 null）", setpath("telecom", nullTerm: false, conn: true, target: false)),

            ("SETPATH 退回根", root()),
            ("SETPATH telecom（UTF-16BE 带 null 终止）", setpath("telecom", nullTerm: true, conn: true, target: false)),

            ("SETPATH 退回根", root()),
            ("SETPATH msg（UTF-16BE 无 null）", setpath("msg", nullTerm: false, conn: true, target: false)),

            ("SETPATH 退回根", root()),
            ("SETPATH inbox（UTF-16BE 无 null）", setpath("inbox", nullTerm: false, conn: true, target: false)),

            ("SETPATH 退回根", root()),
            ("SETPATH telecom（不带 Connection ID）", setpath("telecom", nullTerm: false, conn: false, target: false)),

            ("SETPATH 退回根", root()),
            ("SETPATH telecom（附 Target header）", setpath("telecom", nullTerm: false, conn: true, target: true)),

            ("SETPATH 退回根", root()),
            ("SETPATH telecom（Name 用 UTF-8 裸字节）", setpath("telecom", nullTerm: false, conn: true, target: false, utf8: true)),

            ("SETPATH 退回根", root()),
            ("GET x-bt/MAP-msg-listing（无 Name）", get("x-bt/MAP-msg-listing", name: nil)),
            ("GET x-bt/MAP-msg-listing + Name=inbox", get("x-bt/MAP-msg-listing", name: "inbox")),
        ]
    }

    func sendNext() {
        guard idx < queue.count else {
            emit("")
            emit("=== 全部探测完成 ===")
            finish()
            return
        }
        let (label, packet) = queue[idx]
        idx += 1
        bodyBytes = []
        emit("----------------------------------------")
        emit("[\(idx)/\(queue.count)] \(label)")
        emit("    → \(hex(packet))")
        token += 1
        armTimeout()
        write(packet)
    }

    func write(_ bytes: [UInt8]) {
        var buf = bytes
        let rc = channel?.writeSync(&buf, length: UInt16(buf.count))
        if rc != kIOReturnSuccess {
            emit("    ✗ 写入返回码 \(String(describing: rc))")
        }
    }

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
        token += 1   // 取消本步超时
        guard let op = bytes.first else { return }

        let isSuccess = (op & 0xF0) == 0xA0
        let isContinue = (op == 0x90)
        let tag = isSuccess ? "成功" : (isContinue ? "继续" : "拒绝")
        emit("    ← \(bytes.count) 字节  0x\(String(format: "%02X", op)) \(tag)")
        emit("      \(hexShort(bytes))")

        let headers = parseHeaders(bytes)

        for (id, value) in headers where id == HDR_CONNID {
            if !connected {
                connectionID = value
                connected = true
                emit("      ↳ Connection ID = \(hex(value))")
            }
        }

        // 首次 Connect 成功后铺开探测队列
        if queue.isEmpty {
            guard isSuccess else {
                emit("    ✗ Connect 未成功，终止")
                finish()
                return
            }
            emit("      ✓ Connect 成功")
            emit("")
            buildQueue()
            sendNext()
            return
        }

        // GET 分片：继续取，不推进队列
        if isContinue {
            for (id, value) in headers where id == HDR_BODY || id == HDR_END_OF_BODY {
                bodyBytes += value
            }
            emit("      （分片，继续取）")
            token += 1
            armTimeout()
            write(frame(opcode: OBEX_GET, body: withConnID([])))
            return
        }

        for (id, value) in headers where id == HDR_BODY || id == HDR_END_OF_BODY {
            bodyBytes += value
        }

        if !bodyBytes.isEmpty {
            let text = String(decoding: bodyBytes, as: UTF8.self)
            let shown = text.count > 2000 ? String(text.prefix(2000)) + "\n…（截断）" : text
            emit("      Body \(bodyBytes.count) 字节：")
            emit(shown)
        }

        sendNext()
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        emit("[!] 通道已关闭")
    }

    func finish() {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

emit("========================================")
emit(" MAP 路径探测")
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
emit("已连接   : \(device.isConnected() ? "是" : "否")")
emit("通道     : \(channelID)")
emit("")

let probe = Probe()
probe.open(device: device, channelID: channelID)

CFRunLoopRunInMode(.defaultMode, 60.0, false)
emit("")
emit("=== 结束 ===")
