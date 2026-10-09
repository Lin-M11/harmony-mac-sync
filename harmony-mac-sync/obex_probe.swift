import Foundation
import IOBluetooth

// 定位 MAP / PBAP / HFP 服务的 RFCOMM 通道号
// 用法: ./OBEXProbe <设备蓝牙地址>

let logPath = "/tmp/obex_probe_result.txt"
var logBuffer = ""
try? "".write(toFile: logPath, atomically: true, encoding: .utf8)

func emit(_ items: Any...) {
    let line = items.map { String(describing: $0) }.joined(separator: " ")
    print(line)
    logBuffer += line + "\n"
    try? logBuffer.write(toFile: logPath, atomically: true, encoding: .utf8)
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "E8-1E-92-55-2D-D4"

func shortUUID(_ obj: Any) -> String {
    let desc = String(describing: obj)
    if let r = desc.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                          options: .regularExpression) {
        let up = String(desc[r]).uppercased()
        if up.hasPrefix("0000") && up.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return "0x" + String(up.dropFirst(4).prefix(4))
        }
        return up
    }
    return "?"
}

let targets: [(String, String)] = [
    ("SMS/MMS", "MAP  短信服务 (MSE)"),
    ("OBEX Phonebook Access Server", "PBAP 通讯录 (PSE)"),
    ("Handsfree Gateway", "HFP  音频网关 (AG)"),
]

emit("========================================")
emit(" OBEX 通道定位")
emit("========================================")

guard let device = IOBluetoothDevice(addressString: target) else {
    emit("✗ 设备对象构造失败: \(target)")
    exit(1)
}

emit("设备   : \(device.name ?? "?")")
emit("地址   : \(device.addressString ?? "?")")
emit("已配对 : \(device.isPaired() ? "是" : "否")")
emit("")

device.performSDPQuery(nil)
var waited = 0.0
while waited < 10.0 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    waited += 0.5
    if let s = device.services, !s.isEmpty { break }
}

guard let services = device.services, !services.isEmpty else {
    emit("✗ 未取得 SDP 记录")
    exit(2)
}

emit("SDP 记录数: \(services.count)")
emit("----------------------------------------")

var located: [String: (name: String, channel: UInt8)] = [:]

for item in services {
    guard let rec = item as? IOBluetoothSDPServiceRecord else { continue }
    let name = rec.getServiceName() ?? "(无名)"

    var uuids: [String] = []
    if let de = rec.getAttributeDataElement(1), de.getTypeDescriptor() == 3,
       let arr = de.getArrayValue() as? [Any] {
        for e in arr {
            if let el = e as? IOBluetoothSDPDataElement, let u = el.getUUIDValue() {
                uuids.append(shortUUID(u))
            }
        }
    }

    var ch: BluetoothRFCOMMChannelID = 0
    let rc = rec.getRFCOMMChannelID(&ch)
    let chStr = rc == kIOReturnSuccess ? "RFCOMM \(ch)" : "无 RFCOMM"

    emit("\(name)   [\(uuids.joined(separator: ", "))]   \(chStr)")

    for t in targets where t.0 == name {
        if rc == kIOReturnSuccess {
            located[t.0] = (name, ch)
        }
    }
}

emit("----------------------------------------")
emit("目标服务通道")
emit("----------------------------------------")

for (key, label) in targets {
    if let hit = located[key] {
        emit("✓ \(label)")
        emit("      服务名 \(hit.name)   通道 \(hit.channel)")
    } else {
        emit("✗ \(label)")
    }
}
