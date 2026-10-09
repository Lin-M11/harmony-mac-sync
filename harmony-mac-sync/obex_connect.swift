import Foundation
import IOBluetooth

// OBEX 握手测试：连接 MAP 消息服务
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

// OBEX opcode
let OBEX_CONNECT: UInt8 = 0x80
let OBEX_GET: UInt8 = 0x03
let OBEX_SETPATH: UInt8 = 0x85

// OBEX header ID
let HDR_NAME: UInt8 = 0x01
let HDR_TYPE: UInt8 = 0x42
let HDR_TARGET: UInt8 = 0x46

// MAP Message Access Server 的 OBEX target UUID
let MAS_UUID: [UInt8] = [
    0xBB, 0x58, 0x2B, 0x40, 0x42, 0x0C, 0x11, 0xDB,
    0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
]

func asciiBytes(_ s: String) -> [UInt8] {
    Array(s.utf8)
}

// 构造带长度前缀的 OBEX 报文
func frame(opcode: UInt8, body: [UInt8]) -> [UInt8] {
    let total = 3 + body.count
    return [opcode, UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)] + body
}

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var stage = 0
    var done = false

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
        emit("    ✓ 通道已建立，开始 OBEX 握手")
        emit("")
        sendConnect()
    }

    func sendConnect() {
        // OBEX Connect 请求：Version / Flags / MaxPacketLength 必须在 headers 之前
        var body: [UInt8] = [0x10, 0x00, 0x02, 0x00]
        body += [HDR_TARGET, 0x00, 0x14] + MAS_UUID
        let packet = frame(opcode: OBEX_CONNECT, body: body)

        emit("[3] 发送 OBEX Connect（\(packet.count) 字节）")
        emit("    \(hex(packet))")
        stage = 1
        write(packet)
    }

    func sendSetPath(_ folder: String) {
        var body: [UInt8] = [0x01, 0x00]
        for scalar in folder.utf16 {
            body.append(UInt8((scalar >> 8) & 0xFF))
            body.append(UInt8(scalar & 0xFF))
        }
        body += [0x00, 0x00]
        let packet = frame(opcode: OBEX_SETPATH, body: body)

        emit("[\(stage + 2)] SETPATH → \(folder)（\(packet.count) 字节）")
        write(packet)
        stage += 1
    }

    func sendGetListing() {
        var body: [UInt8] = []
        let typeStr = asciiBytes("x-bt/MAP-msg-listing")
        body += [HDR_TYPE, UInt8(((typeStr.count + 3) >> 8) & 0xFF), UInt8((typeStr.count + 3) & 0xFF)] + typeStr

        let nameStr = asciiBytes("inbox")
        body += [HDR_NAME, UInt8(((nameStr.count + 3) >> 8) & 0xFF), UInt8((nameStr.count + 3) & 0xFF)] + nameStr

        let packet = frame(opcode: OBEX_GET, body: body)

        emit("[\(stage + 2)] GET x-bt/MAP-msg-listing（\(packet.count) 字节）")
        emit("    \(hex(packet))")
        write(packet)
        stage += 1
    }

    func write(_ bytes: [UInt8]) {
        var buf = bytes
        let rc = channel?.writeSync(&buf, length: UInt16(buf.count))
        emit("    写入返回码 \(String(describing: rc))")
        emit("")
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        emit("[←] 收到 \(dataLength) 字节")
        emit("    \(hex(Array(bytes.prefix(64))))")

        guard let op = bytes.first else { return }
        let code = op & 0x7F
        let ok = (op & 0x80) != 0
        emit("    响应码 0x\(String(format: "%02X", op))  \(ok ? "成功" : "失败")")

        if !ok {
            emit("    ✗ 服务端拒绝，握手终止")
            finish()
            return
        }

        switch code {
        case 0x00:  // Connect 响应
            emit("    ✓ OBEX Connect 成功")
            emit("")
            sendSetPath("telecom")
        case 0x05:  // SetPath 响应
            if stage == 2 {
                sendSetPath("msg")
            } else if stage == 3 {
                sendSetPath("inbox")
            } else if stage == 4 {
                emit("    ✓ 已进入 telecom/msg/inbox")
                emit("")
                sendGetListing()
            } else {
                finish()
            }
        case 0x01:  // Get 响应（继续）
            emit("    ✓ 收到消息列表数据")
            emit("")
            emit("=== 握手链路完整 ===")
            finish()
        case 0x03:  // 最终响应
            emit("    ✓ GET 完成")
            emit("")
            emit("=== 握手链路完整 ===")
            finish()
        default:
            emit("    未预期的响应码，结束")
            finish()
        }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        emit("[!] 通道已关闭")
    }

    func finish() {
        done = true
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

CFRunLoopRunInMode(.defaultMode, 15.0, false)
emit("")
emit("=== 结束 ===")
