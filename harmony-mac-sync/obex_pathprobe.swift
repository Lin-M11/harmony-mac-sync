import Foundation
import IOBluetooth

// MAP 路径探测：在一条 OBEX 会话上依次尝试多种 SETPATH / GET 写法，
// 打印每一步的原始响应，用来定位服务端接受哪种形式。
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

// 阶段二用：随机 UUID，验证服务端是否校验 Target
let BOGUS_UUID: [UInt8] = [
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
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

// 收到 0x90 之后怎么处理
enum ContinueMode {
    case resend   // 再发一个空 GET 续取
    case wait     // 什么都不发，等服务端自己把 Body 推过来
}

struct Step {
    let label: String
    let packet: [UInt8]
    let cont: ContinueMode
    let maxChunks: Int

    init(_ label: String, _ packet: [UInt8], _ cont: ContinueMode = .resend, _ maxChunks: Int = 0) {
        self.label = label
        self.packet = packet
        self.cont = cont
        self.maxChunks = maxChunks
    }
}

let STEP_TIMEOUT: Double = 2.5
let PACE_DELAY: Double = 0.15

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var connectionID: [UInt8]?
    var queue: [Step] = []
    var idx = 0
    var rxBuffer: [UInt8] = []
    var token = 0
    var bodyBytes: [UInt8] = []
    var chunks = 0
    var connected = false
    var results: [(String, String)] = []
    var device: IOBluetoothDevice?
    var channelID: BluetoothRFCOMMChannelID = 26
    var phase = 1
    var awaitingBogus = false
    var phase2Started = false

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
        self.device = device
        self.channelID = channelID
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

        let uuid = phase == 2 ? BOGUS_UUID : MAS_UUID
        var body: [UInt8] = [0x10, 0x00, 0x02, 0x00]
        body += lenHeader(HDR_TARGET, uuid)
        emit(phase == 2 ? "[P2] OBEX Connect（随机 UUID）" : "[3] OBEX Connect")
        emit("    → \(hex(frame(opcode: OBEX_CONNECT, body: body)))")
        if phase == 2 { awaitingBogus = true }
        token += 1
        armTimeout()
        write(frame(opcode: OBEX_CONNECT, body: body))
    }

    func startPhase2() {
        guard !phase2Started else { return }
        phase2Started = true
        emit("")
        emit("========================================")
        emit(" 阶段二：Connect 用随机 UUID")
        emit(" 目的：判断服务端是否校验 Target header")
        emit("========================================")
        phase = 2
        rxBuffer.removeAll()
        _ = channel?.close()
        channel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let dev = self.device else { self.finish(); return }
            var ch: IOBluetoothRFCOMMChannel? = nil
            let rc = dev.openRFCOMMChannelAsync(&ch, withChannelID: self.channelID, delegate: self)
            emit("    重新打开通道，返回码 \(rc)")
            self.channel = ch
        }
    }

    func armTimeout() {
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + STEP_TIMEOUT) {
            guard t == self.token else { return }
            if self.phase == 2 {
                emit("    ⏱ 无响应")
                self.finish()
                return
            }
            emit("    ⏱ 无响应，进入下一步")
            self.record("超时无响应")
            self.sendNext()
        }
    }

    func record(_ code: String) {
        let label = idx >= 1 && idx <= queue.count ? queue[idx - 1].label : "(Connect)"
        results.append((label, code))
    }

    func buildQueue() {
        guard let cid = connectionID else { return }

        func conn(_ b: [UInt8]) -> [UInt8] { [HDR_CONNID] + cid + b }

        func setpath(_ folder: String, conn: Bool, target: Bool) -> [UInt8] {
            var body: [UInt8] = [0x00, 0x00]
            body += lenHeader(HDR_NAME, utf16be(folder))
            if target { body += lenHeader(HDR_TARGET, MAS_UUID) }
            return frame(opcode: OBEX_SETPATH, body: conn ? withConnID(body) : body)
        }

        func get(_ type: String?, _ name: String?, conn: Bool, target: Bool) -> [UInt8] {
            var body: [UInt8] = []
            if let t = type { body += lenHeader(HDR_TYPE, Array(t.utf8)) }
            if let n = name { body += lenHeader(HDR_NAME, Array(n.utf8)) }
            if target { body += lenHeader(HDR_TARGET, MAS_UUID) }
            return frame(opcode: OBEX_GET, body: conn ? withConnID(body) : body)
        }

        func root(target: Bool) -> [UInt8] {
            var body: [UInt8] = [0x01, 0x00]
            if target { body += lenHeader(HDR_TARGET, MAS_UUID) }
            return frame(opcode: OBEX_SETPATH, body: withConnID(body))
        }

        queue = [
            // —— GET 矩阵：验证 Target header 是否为关键 ——
            Step("GET x-bt/MAP-msg-listing + Name=inbox（ConnID + Target）",
                 get("x-bt/MAP-msg-listing", "inbox", conn: true, target: true), .resend, 6),
            Step("GET x-obex/folder-listing（ConnID + Target）",
                 get("x-obex/folder-listing", nil, conn: true, target: true), .resend, 6),
            Step("GET x-bt/MAP-msg-listing + Name=inbox（ConnID，无 Target）",
                 get("x-bt/MAP-msg-listing", "inbox", conn: true, target: false), .resend, 6),

            // —— SETPATH 链路：全程带 Target ——
            Step("SETPATH telecom（ConnID + Target）", setpath("telecom", conn: true, target: true)),
            Step("SETPATH msg（ConnID + Target）", setpath("msg", conn: true, target: true)),
            Step("SETPATH inbox（ConnID + Target）", setpath("inbox", conn: true, target: true)),
            Step("GET x-bt/MAP-msg-listing + Name=inbox（进入 inbox 后，ConnID + Target）",
                 get("x-bt/MAP-msg-listing", "inbox", conn: true, target: true), .resend, 6),

            Step("SETPATH 退回根（Flags=0x01，ConnID + Target）", root(target: true)),
            Step("SETPATH telecom/msg/inbox（ConnID + Target）", setpath("telecom/msg/inbox", conn: true, target: true)),
        ]
    }

    func sendNext() {
        guard idx < queue.count else {
            emit("")
            emit("========================================")
            emit(" 结果汇总")
            emit("========================================")
            for (i, r) in results.enumerated() {
                emit("[\(i + 1)] \(r.1)  ←  \(r.0)")
            }
            startPhase2()
            return
        }
        let step = queue[idx]
        idx += 1
        bodyBytes = []
        chunks = 0
        emit("----------------------------------------")
        emit("[\(idx)/\(queue.count)] \(step.label)")
        emit("    → \(hex(step.packet))")
        token += 1
        armTimeout()
        DispatchQueue.main.asyncAfter(deadline: .now() + PACE_DELAY) {
            self.write(step.packet)
        }
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
        token += 1
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

        if awaitingBogus {
            awaitingBogus = false
            emit("")
            if isSuccess {
                emit("    结论：服务端**接受**随机 UUID —— Connect 阶段不校验 Target")
            } else {
                emit("    结论：服务端**拒绝**随机 UUID —— Connect 阶段会校验 Target，MAS 身份可靠")
            }
            finish()
            return
        }

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

        for (id, value) in headers where id == HDR_BODY || id == HDR_END_OF_BODY {
            bodyBytes += value
        }

        if isContinue {
            chunks += 1
            switch queue[idx - 1].cont {
            case .wait:
                emit("      （等服务端继续推送…）")
                token += 1
                armTimeout()
                return
            case .resend:
                if chunks < queue[idx - 1].maxChunks {
                    emit("      （续传 \(chunks)/\(queue[idx - 1].maxChunks)）")
                    token += 1
                    armTimeout()
                    write(frame(opcode: OBEX_GET, body: withConnID([])))
                    return
                }
                emit("      ✗ 达到续传上限 \(queue[idx - 1].maxChunks)，本步结束")
                record("0x90 ×\(chunks) 后放弃")
                sendNext()
                return
            }
        }

        record("0x\(String(format: "%02X", op)) \(tag)")

        if !bodyBytes.isEmpty {
            let text = String(decoding: bodyBytes, as: UTF8.self)
            let shown = text.count > 1500 ? String(text.prefix(1500)) + "\n…（截断）" : text
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

CFRunLoopRunInMode(.defaultMode, 75.0, false)
emit("")
emit("=== 结束 ===")
