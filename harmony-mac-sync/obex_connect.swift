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
// 蓝牙 UUID 在 SDP 中按小端序存储，OBEX Target header 常见为大端，两种都试
let MAS_UUID_VARIANTS: [(String, [UInt8])] = [
    ("大端", [
        0xBB, 0x58, 0x2B, 0x40, 0x42, 0x0C, 0x11, 0xDB,
        0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
    ]),
    ("小端", [
        0x40, 0x2B, 0x58, 0xBB, 0x0C, 0x42, 0xDB, 0x11,
        0xB0, 0xDE, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
    ]),
]

func asciiBytes(_ s: String) -> [UInt8] {
    Array(s.utf8)
}

func frame(opcode: UInt8, body: [UInt8]) -> [UInt8] {
    let total = 3 + body.count
    return [opcode, UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)] + body
}

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var stage = 0
    var uuidAttempt = 0
    var getChunks = 0
    var connectionID: [UInt8]?
    var getBody: [UInt8] = []

    // 服务端返回 Connection ID 后，后续请求必须带上
    func withConnID(_ body: [UInt8]) -> [UInt8] {
        guard let cid = connectionID else { return body }
        return [0xCB] + cid + body
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

    func sendConnect() {
        let (label, uuid) = MAS_UUID_VARIANTS[uuidAttempt]
        var body: [UInt8] = [0x10, 0x00, 0x02, 0x00]
        // Target header 长度 = ID(1) + 长度字段(2) + UUID(16) = 19 = 0x13
        body += [HDR_TARGET, 0x00, 0x13] + uuid
        let packet = frame(opcode: OBEX_CONNECT, body: body)

        emit("[3] OBEX Connect（\(packet.count) 字节，Target UUID \(label)序）")
        emit("    \(hex(packet))")
        stage = 1
        write(packet)
    }

    func sendSetPath(_ folder: String) {
        // Flags: bit0 = 退回上级(1)/进入下级(0)，bit1 = 不存在时不创建
        // 这里是逐级下钻 telecom → msg → inbox，用 0x00
        var body: [UInt8] = [0x00, 0x00]
        for scalar in folder.utf16 {
            body.append(UInt8((scalar >> 8) & 0xFF))
            body.append(UInt8(scalar & 0xFF))
        }
        body += [0x00, 0x00]
        let packet = frame(opcode: OBEX_SETPATH, body: withConnID(body))

        let n = stage
        stage = n + 1
        emit("[\(n + 2)] SETPATH → \(folder)（\(packet.count) 字节）")
        write(packet)
    }

    func sendGetListing() {
        var body: [UInt8] = []
        let typeStr = asciiBytes("x-bt/MAP-msg-listing")
        body += [HDR_TYPE, UInt8(((typeStr.count + 3) >> 8) & 0xFF), UInt8((typeStr.count + 3) & 0xFF)] + typeStr

        let nameStr = asciiBytes("inbox")
        body += [HDR_NAME, UInt8(((nameStr.count + 3) >> 8) & 0xFF), UInt8((nameStr.count + 3) & 0xFF)] + nameStr

        let packet = frame(opcode: OBEX_GET, body: withConnID(body))
        let n = stage
        stage = n + 1
        emit("[\(n + 2)] GET x-bt/MAP-msg-listing（\(packet.count) 字节）")
        emit("    \(hex(packet))")
        write(packet)
    }

    // GET 的分片续传：不带 header，只带 Connection ID
    func sendGetContinue() {
        let packet = frame(opcode: OBEX_GET, body: withConnID([]))
        emit("    → 继续 GET（\(packet.count) 字节）")
        write(packet)
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
        emit("    \(hex(Array(bytes.prefix(80))))")

        guard let op = bytes.first else { return }

        // OBEX 响应码：0xA0-0xAF 成功；0x90 继续；其余为失败
        let isSuccess = (op & 0xF0) == 0xA0
        let isContinue = (op == 0x90)
        emit("    响应码 0x\(String(format: "%02X", op))  \(isSuccess ? "成功" : (isContinue ? "继续" : "失败"))")

        // 记录服务端下发的 Connection ID（0xCB），后续所有请求都要带上
        for (id, value) in parseHeaders(bytes) where id == 0xCB {
            connectionID = value
            emit("    ↳ Connection ID = \(hex(value))")
        }

        if !isSuccess && !isContinue {
            if stage == 1, uuidAttempt + 1 < MAS_UUID_VARIANTS.count {
                uuidAttempt += 1
                emit("    ↻ 换一种字节序重试")
                emit("")
                sendConnect()
                return
            }
            emit("    ✗ 握手终止")
            finish()
            return
        }

        switch stage {
        case 1:
            emit("    ✓ OBEX Connect 成功")
            emit("")
            sendSetPath("telecom")
        case 2:
            sendSetPath("msg")
        case 3:
            sendSetPath("inbox")
        case 4:
            emit("    ✓ 已进入 telecom/msg/inbox")
            emit("")
            sendGetListing()
        case 5:
            getChunks += 1
            // 响应体从第 3 字节起是 header 流，累积 Body header(0x48) 的内容
            for (id, value) in parseHeaders(bytes) where id == 0x48 {
                getBody += value
            }
            if isContinue {
                emit("    （数据分片 \(getChunks)，继续接收）")
                sendGetContinue()
            } else {
                emit("    ✓ 消息列表接收完成，共 \(getChunks) 片")
                emit("")
                if getBody.isEmpty {
                    emit("=== 握手链路完整：服务端返回成功，列表为空 ===")
                } else {
                    let text = String(decoding: getBody, as: UTF8.self)
                    emit("=== 握手链路完整：已读取到短信列表（\(getBody.count) 字节）===")
                    emit("")
                    emit(text)
                }
                finish()
            }
        default:
            finish()
        }
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

CFRunLoopRunInMode(.defaultMode, 20.0, false)
emit("")
emit("=== 结束 ===")
