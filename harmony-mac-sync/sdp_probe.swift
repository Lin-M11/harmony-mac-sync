import Foundation
import IOBluetooth

// 用法: swift sdp_probe.swift [设备地址]
// 地址格式: E8-1E-92-55-2D-D4

let logPath = "/tmp/sdp_probe_result.txt"
var logBuffer = ""
try? "".write(toFile: logPath, atomically: true, encoding: .utf8)

// 输出同时走 stdout 和文件（open 启动时 stdout 不可见）
func emit(_ items: Any...) {
    let line = items.map { String(describing: $0) }.joined(separator: " ")
    print(line)
    logBuffer += line + "\n"
    try? logBuffer.write(toFile: logPath, atomically: true, encoding: .utf8)
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "E8-1E-92-55-2D-D4"

func shortUUID(_ s: String) -> String {
    let up = s.uppercased()
    if up.hasPrefix("0000") && up.hasSuffix("-0000-1000-8000-00805F9B34FB") {
        return "0x" + String(up.dropFirst(4).prefix(4))
    }
    return up
}

// IOBluetoothSDPUUID 没有直接取字符串的方法，从 description 里正则提取
func extractUUID(_ obj: Any) -> String? {
    let desc = String(describing: obj)
    if let r = desc.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                          options: .regularExpression) {
        return shortUUID(String(desc[r]))
    }
    return "?" + String(desc.prefix(40))
}

let known: [String: String] = [
    "0x1132": "MAP  Message Access Server (短信服务)",
    "0x1133": "MAP  Message Notification Server (新消息事件)",
    "0x112F": "PBAP Phonebook Access PSE (通讯录)",
    "0x1130": "PBAP Phonebook Access PCE",
    "0x111F": "HFP  Hands-Free Audio Gateway (来电)",
    "0x111E": "HFP  Hands-Free Unit",
    "0x110E": "A2DP Source (音频)",
    "0x110B": "A2DP Sink",
    "0x1108": "Headset (HSP)",
    "0x1112": "Headset Audio Gateway",
    "0x1105": "OBEX Object Push (文件传输)",
    "0x1124": "HID (输入设备)",
    "0x1800": "GAP (通用访问)",
    "0x1801": "GATT",
]

emit("========================================")
emit(" SDP 服务探查")
emit("========================================")

emit("[1/5] 构造设备对象 ...")
guard let device = IOBluetoothDevice(addressString: target) else {
    emit("✗ 无法构造设备对象，地址格式可能不对: \(target)")
    exit(1)
}

emit("[2/5] 设备对象 OK，读取属性 ...")
emit("名称     : \(device.name ?? "(未知)")")
emit("地址     : \(device.addressString ?? "(未知)")")
emit("已配对   : \(device.isPaired() ? "是" : "否")")
emit("已连接   : \(device.isConnected() ? "是" : "否")")
emit("RSSI     : \(device.rawRSSI())")
emit("")
emit("[3/5] 发起 SDP 查询（最多等 10 秒）...")

let status = device.performSDPQuery(nil)
emit("performSDPQuery 返回码: \(status)")
emit("")

// 轮询等待 SDP 结果
var waited = 0.0
while waited < 10.0 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    waited += 0.5
    if let s = device.services, !s.isEmpty { break }
}

guard let services = device.services, !services.isEmpty else {
    emit("✗ 没有拿到任何服务记录。")
    emit("")
    emit("可能原因：")
    emit("  1) 蓝牙权限未授予（系统设置 → 隐私与安全性 → 蓝牙，把终端加进去）")
    emit("  2) 设备处于休眠 / 不在范围内")
    emit("  3) 手机侧未响应 SDP 查询")
    exit(2)
}

emit("✓ 共发现 \(services.count) 个服务记录")
emit("========================================")

var found: Set<String> = []

for (i, item) in services.enumerated() {
    guard let rec = item as? IOBluetoothSDPServiceRecord else { continue }
    let name = rec.getServiceName() ?? "(无名)"
    var uuids: [String] = []

    if let de = rec.getAttributeDataElement(1), de.getTypeDescriptor() == 3,
       let arr = de.getArrayValue() as? [Any] {
        for e in arr {
            if let el = e as? IOBluetoothSDPDataElement,
               let u = el.getUUIDValue(), let s = extractUUID(u) {
                uuids.append(s)
                found.insert(s)
            }
        }
    }

    let uuidStr = uuids.isEmpty ? "(无 UUID)" : uuids.joined(separator: ", ")
    emit("[\(i)] \(name)")
    emit("      \(uuidStr)")
}

emit("========================================")
emit(" 关键能力判定")
emit("========================================")

let checks: [(String, String)] = [
    ("0x1132", "MAP 短信服务        → 短信读取"),
    ("0x1133", "MAP 新消息事件      → 短信实时推送"),
    ("0x112F", "PBAP 通讯录         → 号码反查姓名"),
    ("0x111F", "HFP 音频网关        → 来电提醒"),
]

for (code, label) in checks {
    let hit = found.contains(code)
    emit("\(hit ? "✓ 有" : "✗ 无")  \(label)")
}

emit("")
if found.contains("0x1132") {
    emit("结论：手机暴露了 MAP 服务，蓝牙直连方案成立。")
} else {
    emit("结论：未发现 MAP 服务，需要进一步排查（见方案文档 §7）。")
}
