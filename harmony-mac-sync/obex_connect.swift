import Foundation
import IOBluetooth

// OBEX 握手测试：连接 MAP 消息服务，逐级进入 inbox，读取短信列表
// 用法: ./OBEXConnect <设备地址> [RFCOMM通道]

let logPath = "/tmp/obex_connect_result.txt"
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

func hexText(_ bytes: [UInt8]) -> String {
    let head = bytes.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
    return bytes.count > 64 ? head + " …(共 \(bytes.count) 字节)" : head
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

// MAP Message Access Server 的 OBEX target UUID（大端）
let MAS_UUID: [UInt8] = [
    0xBB, 0x58, 0x2B, 0x40, 0x42, 0x0C, 0x11, 0xDB,
    0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
]

// MAP 收件箱路径。两种常见层级都试：MSE 根即 telecom，或根下有 telecom。
let PATH_PLANS: [[String]] = [
    ["telecom", "msg", "inbox"],
    ["msg", "inbox"],
]

// 变长 header（ID + 2 字节长度 + 值），长度含 header 自身 3 字节
func lenHeader(_ id: UInt8, _ value: [UInt8]) -> [UInt8] {
    let total = value.count + 3
    return [id, UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)] + value
}

// UTF-16BE 编码
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

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var connectionID: [UInt8]?

    // 正在等待响应的请求类型
    enum Awaiting { case connect, setpath, get }
    var awaiting: Awaiting = .connect

    var planIndex = 0
    var stepIndex = 0
    var getChunks = 0
    var bodyBytes: [UInt8] = []
    var rxBuffer: [UInt8] = []
    var logIndex = 0

    // 服务端下发 Connection ID 后，后续请求都要带上
    func withConnID(_ body: [UInt8]) -> [UInt8] {
        guard let cid = connectionID else { return body }
        return [HDR_CONNID] + cid + body
    }

    // 解析 OBEX 报文里的 header 列表（跳过 opcode 1 字节 + length 2 字节）
    // header ID 高 2 位决定长度形式：
    //   00 → 共 2 字节；01 → 3 字节头 + 变长值；10 → 共 3 字节；11 → 共 5 字节
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
        sendConnect()
    }

    func nextLogIndex() -> Int {
        logIndex += 1
        return logIndex
    }

    func sendConnect() {
        var body: [UInt8] = [0x10, 0x00, 0x02, 0x00]   // Version / Flags / MaxPacketLength
        body += lenHeader(HDR_TARGET, MAS_UUID)
        let packet = frame(opcode: OBEX_CONNECT, body: body)

        emit("[\(nextLogIndex())] OBEX Connect（\(packet.count) 字节）")
        emit("    \(hex(packet))")
        awaiting = .connect
        write(packet)
    }

    func sendSetPath(_ folder: String) {
        // Flags: bit0 = 退回上级(1)/进入下级(0)，bit1 = 不存在时不创建
        var body: [UInt8] = [0x00, 0x00]
        body += lenHeader(HDR_NAME, utf16be(folder))
        let packet = frame(opcode: OBEX_SETPATH, body: withConnID(body))

        emit("[\(nextLogIndex())] SETPATH → \(folder)（\(packet.count) 字节）")
        emit("    \(hex(packet))")
        awaiting = .setpath
        write(packet)
    }

    func sendGetListing() {
        var body: [UInt8] = []
        body += lenHeader(HDR_TYPE, Array("x-bt/MAP-msg-listing".utf8))
        body += lenHeader(HDR_NAME, Array("inbox".utf8))
        let packet = frame(opcode: OBEX_GET, body: withConnID(body))

        emit("[\(nextLogIndex())] GET x-bt/MAP-msg-listing（\(packet.count) 字节）")
        emit("    \(hex(packet))")
        awaiting = .get
        write(packet)
    }

    // GET 分片续传：不带 header，只带 Connection ID
    func sendGetContinue() {
        let packet = frame(opcode: OBEX_GET, body: withConnID([]))
        emit("    → 继续 GET（\(packet.count) 字节）")
        awaiting = .get
        write(packet)
    }

    func write(_ bytes: [UInt8]) {
        var buf = bytes
        let rc = channel?.writeSync(&buf, length: UInt16(buf.count))
        if rc != kIOReturnSuccess {
            emit("    ✗ 写入返回码 \(String(describing: rc))")
        }
        emit("")
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        rxBuffer += Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        emit("[←] 收到 \(dataLength) 字节（缓冲 \(rxBuffer.count)）")

        // 按 OBEX 长度字段切出完整报文，处理粘包/拆包
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
        guard let op = bytes.first else { return }
        emit("    报文 \(bytes.count) 字节: \(hexText(bytes))")

        let isSuccess = (op & 0xF0) == 0xA0
        let isContinue = (op == 0x90)
        emit("    响应码 0x\(String(format: "%02X", op))  \(isSuccess ? "成功" : (isContinue ? "继续" : "失败"))")

        let headers = parseHeaders(bytes)

        // 记录 Connection ID
        for (id, value) in headers where id == HDR_CONNID {
            connectionID = value
            emit("    ↳ Connection ID = \(hex(value))")
        }

        if !isSuccess && !isContinue {
            onFailure()
            return
        }

        switch awaiting {
        case .connect:
            emit("    ✓ OBEX Connect 成功")
            emit("")
            planIndex = 0
            stepIndex = 0
            sendSetPath(PATH_PLANS[planIndex][stepIndex])

        case .setpath:
            let folder = PATH_PLANS[planIndex][stepIndex]
            emit("    ✓ 已进入 \(folder)")
            stepIndex += 1
            if stepIndex < PATH_PLANS[planIndex].count {
                emit("")
                sendSetPath(PATH_PLANS[planIndex][stepIndex])
            } else {
                emit("    ✓ 路径就绪：\(PATH_PLANS[planIndex].joined(separator: "/"))")
                emit("")
                sendGetListing()
            }

        case .get:
            getChunks += 1
            for (id, value) in headers where id == HDR_BODY || id == HDR_END_OF_BODY {
                bodyBytes += value
            }
            if isContinue {
                emit("    （分片 \(getChunks)，继续接收）")
                sendGetContinue()
            } else {
                emit("    ✓ 列表接收完成，共 \(getChunks) 片")
                emit("")
                reportBody()
                finish()
            }
        }
    }

    func onFailure() {
        switch awaiting {
        case .setpath where stepIndex == 0 && planIndex + 1 < PATH_PLANS.count:
            planIndex += 1
            stepIndex = 0
            emit("    ↻ 换一种层级起点：\(PATH_PLANS[planIndex].joined(separator: "/"))")
            emit("")
            sendSetPath(PATH_PLANS[planIndex][stepIndex])
        default:
            emit("    ✗ 握手终止")
            finish()
        }
    }

    func reportBody() {
        guard !bodyBytes.isEmpty else {
            emit("=== 链路完整：服务端返回成功，列表为空 ===")
            return
        }
        let text = String(decoding: bodyBytes, as: UTF8.self)
        emit("=== 链路完整：短信列表 \(bodyBytes.count) 字节 ===")
        emit("")
        emit(text)
        emit("")
        let count = text.components(separatedBy: "<msg ").count - 1
        emit("=== 解析：约 \(max(count, 0)) 条消息 ===")
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        emit("[!] 通道已关闭")
    }

    func finish() {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

emit("========================================")
emit(" OBEX 握手测试")
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

CFRunLoopRunInMode(.defaultMode, 30.0, false)
emit("")
emit("=== 结束 ===")
