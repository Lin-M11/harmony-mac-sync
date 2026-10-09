import Foundation
import IOBluetooth

// 手机 MAP 能力探查
//
// ServiceClassIDList（0x0001）外层是「数据元素序列」（类型 6），UUID 在它的子元素里，
// 所以判断服务类型用 matchesUUID16，不靠外层类型判断。
//
// 探针会把 MAS 记录里的每个属性都展开，重点读：
//   0x0200 GoepL2capPsm
//   0x0315 MASInstanceID
//   0x0316 SupportedMessageTypes
//   0x0317 SupportedFeatures   ← 里面的「通知注册 / 通知」位决定实时推送是否可行
//
// 用法: ./PhoneCapProbe [设备地址]

let LOG = "/tmp/phone_map_result.txt"
var logBuffer = ""
try? "".write(toFile: LOG, atomically: true, encoding: .utf8)

func emit(_ items: Any...) {
    let line = items.map { String(describing: $0) }.joined(separator: " ")
    print(line)
    logBuffer += line + "\n"
    try? logBuffer.write(toFile: LOG, atomically: true, encoding: .utf8)
}

func hexBytes(_ d: Data) -> String {
    d.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func uuidText(_ el: IOBluetoothSDPDataElement) -> String {
    guard let u = el.getUUIDValue() else { return "?" }
    let desc = String(describing: u)
    if let r = desc.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                          options: .regularExpression) {
        let s = String(desc[r]).uppercased()
        if s.hasPrefix("0000") && s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return "0x" + String(s.dropFirst(4).prefix(4))
        }
        return s
    }
    return desc
}

func render(_ el: IOBluetoothSDPDataElement, _ indent: String) -> String {
    switch el.getTypeDescriptor() {
    case 0:
        return "空"
    case 1, 2:
        if let n = el.getNumberValue() { return "整数 \(n)" }
        if let d = el.getDataValue() { return "大整数 \(hexBytes(d as Data))" }
        return "整数?"
    case 3:
        return "UUID \(uuidText(el))"
    case 4, 8:
        return "字符串 \(el.getStringValue() ?? "?")"
    case 5:
        return "布尔 \(el.getNumberValue()?.boolValue == true ? "真" : "假")"
    case 6, 7:
        let arr = el.getArrayValue() ?? []
        var lines: [String] = ["序列 \(arr.count) 项:"]
        for (i, sub) in arr.enumerated() {
            guard let se = sub as? IOBluetoothSDPDataElement else { continue }
            lines.append("\(indent)  [\(i)] \(render(se, indent + "    "))")
        }
        return lines.joined(separator: "\n")
    default:
        return "类型 \(el.getTypeDescriptor())"
    }
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "E8-1E-92-55-2D-D4"

emit("========================================")
emit(" 手机 MAP 能力探查")
emit("========================================")

guard let device = IOBluetoothDevice(addressString: target) else {
    emit("✗ 无法构造设备对象，地址格式可能不对: \(target)")
    exit(1)
}

emit("名称   : \(device.name ?? "(未知)")")
emit("地址   : \(device.addressString ?? "(未知)")")
emit("已配对 : \(device.isPaired() ? "是" : "否")")
emit("已连接 : \(device.isConnected() ? "是" : "否")")
emit("")
emit("发起 SDP 查询（最多等 12 秒）...")

_ = device.performSDPQuery(nil)

var waited = 0.0
while waited < 12.0 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    waited += 0.5
    if let s = device.services, !s.isEmpty { break }
}

guard let services = device.services, !services.isEmpty else {
    emit("✗ 没有拿到任何服务记录。手机可能没连上，或蓝牙权限没给。")
    exit(2)
}

let records = services.compactMap { $0 as? IOBluetoothSDPServiceRecord }
emit("✓ 共发现 \(records.count) 条服务记录")
emit("========================================")

var masCount = 0
var mnsCount = 0

for (i, rec) in records.enumerated() {
    let name = rec.getServiceName() ?? "(无名)"
    var tags: [String] = []
    if rec.matchesUUID16(0x1132) { tags.append("MAP-MAS"); masCount += 1 }
    if rec.matchesUUID16(0x1133) { tags.append("MAP-MNS"); mnsCount += 1 }
    if rec.matchesUUID16(0x1134) { tags.append("MAP-Profile") }
    if rec.matchesUUID16(0x112F) { tags.append("PBAP-PSE") }
    if rec.matchesUUID16(0x111F) { tags.append("HFP-AG") }
    let suffix = tags.isEmpty ? "" : "   ◀ " + tags.joined(separator: " + ")
    emit("[\(i)] \(name)\(suffix)")
}

emit("")
emit("========================================")
emit(" MAS 记录明细（手机侧的短信服务）")
emit("========================================")

guard let masRec = records.first(where: { $0.matchesUUID16(0x1132) }) else {
    emit("✗ 手机没有暴露 MAS（0x1132）。")
    exit(3)
}

let attrs = masRec.attributes as? [NSNumber: Any] ?? [:]
for key in attrs.keys.sorted(by: { $0.uint16Value < $1.uint16Value }) {
    guard let el = attrs[key] as? IOBluetoothSDPDataElement else { continue }
    emit("\(String(format: "0x%04X", key.uint16Value))  \(render(el, "          "))")
}

emit("")
emit("---- 关键项解读 ----")

var cid: BluetoothRFCOMMChannelID = 0
if masRec.getRFCOMMChannelID(&cid) == kIOReturnSuccess {
    emit("RFCOMM 通道        : \(cid)")
} else {
    emit("RFCOMM 通道        : 读不到")
}

if let el = masRec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0200)),
   let n = el.getNumberValue() {
    emit("GoepL2capPsm       : 0x" + String(n.uint16Value, radix: 16, uppercase: true))
}

if let el = masRec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0315)),
   let n = el.getNumberValue() {
    emit("MASInstanceID      : \(n)")
}

if let el = masRec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0316)),
   let n = el.getNumberValue() {
    let v = n.uint8Value
    var types: [String] = []
    if v & 0x01 != 0 { types.append("SMS") }
    if v & 0x02 != 0 { types.append("MMS") }
    if v & 0x04 != 0 { types.append("Email") }
    if v & 0x08 != 0 { types.append("即时消息") }
    emit("支持的消息类型     : 0x" + String(format: "%02X", v) + "  [" + (types.isEmpty ? "无" : types.joined(separator: " / ")) + "]")
}

if let el = masRec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0317)),
   let n = el.getNumberValue() {
    let v = n.uint32Value
    emit("SupportedFeatures  : 0x" + String(format: "%08X", v))
    emit("   位 0  通知注册 Notification Registration : " + (v & 0x00000001 != 0 ? "支持" : "不支持"))
    emit("   位 1  通知     Notification              : " + (v & 0x00000002 != 0 ? "支持" : "不支持"))
    emit("   位 2  浏览     Browsing                  : " + (v & 0x00000004 != 0 ? "支持" : "不支持"))
    emit("   位 3  数据库标识 Database Identifier    : " + (v & 0x00000008 != 0 ? "支持" : "不支持"))
    emit("   位 4  文件夹版本计数                     : " + (v & 0x00000010 != 0 ? "支持" : "不支持"))
    var setBits: [String] = []
    for b in 0..<32 where (v >> UInt32(b)) & 1 == 1 { setBits.append("\(b)") }
    emit("   置位的位：\(setBits.isEmpty ? "无" : setBits.joined(separator: " "))")
} else {
    emit("SupportedFeatures  : 记录里没有这一项")
}

emit("")
emit("手机侧 MNS 记录    : " + (mnsCount > 0 ? "有 \(mnsCount) 条" : "无"))

emit("")
emit("========================================")
emit(" 结论")
emit("========================================")

if let el = masRec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0317)),
   let n = el.getNumberValue() {
    let v = n.uint32Value
    if v & 0x01 != 0 {
        emit("手机 MAS 声明支持「通知注册」：可以在 Mac 侧发布 MNS 记录后，向手机订阅新消息事件。")
    } else {
        emit("手机 MAS 未声明「通知注册」：手机不接受订阅，实时推送这条路走不通，实时性靠缩短拉取间隔实现。")
    }
} else {
    emit("手机 MAS 没有 SupportedFeatures 属性：无法判断订阅能力，按不支持处理。")
}
