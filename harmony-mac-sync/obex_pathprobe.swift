import Foundation
import IOBluetooth

// MAP 路径探测：每个用例独立开一条 OBEX 会话，一次只变一个因素，避免会话状态互相污染。
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

// SETPATH 报文：Flags + Constants + Name header（+ 可选 Target）
func setpathPacket(_ folder: String, conn: Bool, target: Bool, cid: [UInt8]) -> [UInt8] {
    var body: [UInt8] = [0x00, 0x00]
    body += lenHeader(HDR_NAME, utf16be(folder))
    if target { body += lenHeader(HDR_TARGET, MAS_UUID) }
    if conn { body = [HDR_CONNID] + cid + body }
    return frame(opcode: OBEX_SETPATH, body: body)
}

// GET 报文：Type + Name（+ 可选 Target）
func getPacket(_ type: String?, _ name: String?, conn: Bool, target: Bool, cid: [UInt8]) -> [UInt8] {
    var body: [UInt8] = []
    if let t = type { body += lenHeader(HDR_TYPE, Array(t.utf8)) }
    if let n = name { body += lenHeader(HDR_NAME, Array(n.utf8)) }
    if target { body += lenHeader(HDR_TARGET, MAS_UUID) }
    if conn { body = [HDR_CONNID] + cid + body }
    return frame(opcode: OBEX_GET_FINAL, body: body)
}

struct Scenario {
    let label: String
    let build: ([UInt8]) -> [[UInt8]]
}

// 每个用例独立会话，逐个隔离变量
let scenarios: [Scenario] = [
    Scenario(label: "① SETPATH telecom（无 ConnID，无 Target）") { cid in
        [setpathPacket("telecom", conn: false, target: false, cid: cid)]
    },
    Scenario(label: "② SETPATH telecom（ConnID，无 Target）") { cid in
        [setpathPacket("telecom", conn: true, target: false, cid: cid)]
    },
    Scenario(label: "③ SETPATH telecom（ConnID + Target）") { cid in
        [setpathPacket("telecom", conn: true, target: true, cid: cid)]
    },
    Scenario(label: "④ SETPATH telecom（无 ConnID，有 Target）") { cid in
        [setpathPacket("telecom", conn: false, target: true, cid: cid)]
    },
    Scenario(label: "⑤ 下钻 telecom → msg → inbox（无 ConnID 无 Target），再取列表") { cid in
        [
            setpathPacket("telecom", conn: false, target: false, cid: cid),
            setpathPacket("msg", conn: false, target: false, cid: cid),
            setpathPacket("inbox", conn: false, target: false, cid: cid),
            getPacket("x-bt/MAP-msg-listing", "inbox", conn: false, target: false, cid: cid),
        ]
    },
    Scenario(label: "⑥ 下钻 telecom → msg → inbox（ConnID + Target），再取列表") { cid in
        [
            setpathPacket("telecom", conn: true, target: true, cid: cid),
            setpathPacket("msg", conn: true, target: true, cid: cid),
            setpathPacket("inbox", conn: true, target: true, cid: cid),
            getPacket("x-bt/MAP-msg-listing", "inbox", conn: true, target: true, cid: cid),
        ]
    },
    Scenario(label: "⑦ GET 列表，Name 直接给整条路径 telecom/msg/inbox") { cid in
        [getPacket("x-bt/MAP-msg-listing", "telecom/msg/inbox", conn: false, target: false, cid: cid)]
    },
    Scenario(label: "⑧ GET 列表，Name=msg/inbox") { cid in
        [getPacket("x-bt/MAP-msg-listing", "msg/inbox", conn: false, target: false, cid: cid)]
    },
]

let STEP_TIMEOUT: Double = 2.0
let PACE_DELAY: Double = 0.15
let MAX_CHUNKS = 8

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var device: IOBluetoothDevice?
    var channelID: BluetoothRFCOMMChannelID = 26
    var connectionID: [UInt8]?
    var rxBuffer: [UInt8] = []
    var token = 0

    var scenarioIdx = -1
    var pending: [[UInt8]] = []
    var reqIdx = 0
    var chunks = 0
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
        nextScenario()
    }

    func nextScenario() {
        scenarioIdx += 1
        guard scenarioIdx < scenarios.count else {
            summary()
            finish()
            return
        }
        emit("")
        emit("========================================")
        emit("场景 \(scenarioIdx + 1)/\(scenarios.count)：\(scenarios[scenarioIdx].label)")
        emit("========================================")

        connectionID = nil
        rxBuffer.removeAll()
        pending = []
        reqIdx = 0
        chunks = 0

        if let ch = channel { _ = ch.close() }
        channel = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let dev = self.device else { self.finish(); return }
            var ch: IOBluetoothRFCOMMChannel? = nil
            let rc = dev.openRFCOMMChannelAsync(&ch, withChannelID: self.channelID, delegate: self)
            emit("    打开通道，返回码 \(rc)")
            self.channel = ch
        }
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == kIOReturnSuccess else {
            emit("    ✗ 通道打开失败 status=\(status)")
            nextScenario()
            return
        }
        emit("    通道已建立")
        var body: [UInt8] = [0x10, 0x00, 0x02, 0x00]
        body += lenHeader(HDR_TARGET, MAS_UUID)
        let pkt = frame(opcode: OBEX_CONNECT, body: body)
        emit("    → Connect  \(hex(pkt))")
        token += 1
        armTimeout()
        DispatchQueue.main.asyncAfter(deadline: .now() + PACE_DELAY) { self.write(pkt) }
    }

    func armTimeout() {
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + STEP_TIMEOUT) {
            guard t == self.token else { return }
            emit("    ⏱ 无响应")
            if self.pending.isEmpty {
                self.nextScenario()
            } else {
                self.record("超时无响应")
                self.advance()
            }
        }
    }

    func record(_ code: String) {
        let label = "场景\(scenarioIdx + 1) · 第\(reqIdx + 1)步"
        results.append((label, code))
    }

    func sendNextReq() {
        guard reqIdx < pending.count else {
            nextScenario()
            return
        }
        let pkt = pending[reqIdx]
        emit("    [\(reqIdx + 1)/\(pending.count)] → \(hex(pkt))")
        token += 1
        armTimeout()
        DispatchQueue.main.asyncAfter(deadline: .now() + PACE_DELAY) { self.write(pkt) }
    }

    func advance() {
        reqIdx += 1
        chunks = 0
        sendNextReq()
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
            if connectionID == nil {
                connectionID = value
                emit("      ↳ Connection ID = \(hex(value))")
            }
        }

        // pending 为空说明这是 Connect 的响应
        if pending.isEmpty {
            guard isSuccess else {
                emit("      ✗ Connect 未成功")
                nextScenario()
                return
            }
            emit("      ✓ Connect 成功")
            pending = scenarios[scenarioIdx].build(connectionID ?? [])
            reqIdx = 0
            sendNextReq()
            return
        }

        var body: [UInt8] = []
        for (id, value) in headers where id == HDR_BODY || id == HDR_END_OF_BODY {
            body += value
        }

        if isContinue {
            chunks += 1
            if chunks <= MAX_CHUNKS {
                emit("      （续传 \(chunks)/\(MAX_CHUNKS)）")
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

        if !body.isEmpty {
            let text = String(decoding: body, as: UTF8.self)
            let shown = text.count > 1200 ? String(text.prefix(1200)) + "\n…（截断）" : text
            emit("      Body \(body.count) 字节：")
            emit(shown)
        }

        advance()
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
        // 主动切换场景时会关闭通道，这里不额外处理
    }

    func finish() {
        emit("")
        emit("=== 结束 ===")
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

emit("========================================")
emit(" MAP 路径探测（每用例独立会话）")
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
emit("用例数   : \(scenarios.count)")

let probe = Probe()
probe.start(device: device, channelID: channelID)

CFRunLoopRunInMode(.defaultMode, 100.0, false)
