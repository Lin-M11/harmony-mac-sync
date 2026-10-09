import Foundation
import IOBluetooth

// SDP 记录发布探测
//
// 同一进程里连续发布多条记录会互相干扰（守护进程侧的发布是异步的），
// 所以这里每个用例各起一个进程，由 run_sdpprobe.command 逐个调用。
//
// 每个用例分两步报告：
//   1) 本地解析 —— 只把字典交给框架解析成记录对象，不碰蓝牙守护进程。用来判断「字典格式」对不对。
//   2) 发布     —— 真正把记录挂到本机 SDP 服务器。用来判断「守护进程收不收」。
//
// 用法: ./SDPPublishProbe <用例名>
//       ./SDPPublishProbe list

let l2capU   = IOBluetoothSDPUUID(uuid16: 0x0100)!
let rfcommU  = IOBluetoothSDPUUID(uuid16: 0x0003)!
let obexU    = IOBluetoothSDPUUID(uuid16: 0x0008)!
let browseU  = IOBluetoothSDPUUID(uuid16: 0x1002)!
let mapProfU = IOBluetoothSDPUUID(uuid16: 0x1134)!
let mnsU     = IOBluetoothSDPUUID(uuid16: 0x1133)!

/// 数字元素，值给原始字节（网络序），元素长度取自字节数
func raw(_ bytes: [UInt8]) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data(bytes)]
}

/// 数字元素，值给 NSNumber 并显式指定长度
func num(_ v: Int, _ size: Int) -> [String: Any] {
    ["DataElementType": 1, "DataElementSize": size, "DataElementValue": NSNumber(value: v)]
}

var CASES: [String: [String: Any]] = [:]

// 最小记录：只有类 UUID
CASES["scl"] = [
    "0001 ServiceClassIDList": [mnsU],
]

// 类 UUID + 服务名
CASES["scl-name"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0100 ServiceName": "MAP MNS",
]

// 协议栈：只有 UUID，不带任何参数
CASES["pdl-uuids"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [[l2capU], [rfcommU], [obexU]],
]

// 协议栈：只留 L2CAP 一层
CASES["pdl-l2cap-only"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [[l2capU]],
]

// 协议栈：去掉 L2CAP，只留 RFCOMM + OBEX
CASES["pdl-rfcomm-obex"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [[rfcommU, raw([0x0A])], [obexU]],
]

// 协议栈：数字用原始字节
CASES["pdl-raw"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [
        [l2capU, raw([0x00, 0x03])],
        [rfcommU, raw([0x0A])],
        [obexU],
    ],
]

// 协议栈：数字用 NSNumber + 显式长度
CASES["pdl-numsize"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [
        [l2capU, num(0x0003, 2)],
        [rfcommU, num(0x0A, 1)],
        [obexU],
    ],
]

// 协议栈：数字直接放裸 NSNumber
CASES["pdl-bare"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [
        [l2capU, NSNumber(value: 0x0003)],
        [rfcommU, NSNumber(value: 0x0A)],
        [obexU],
    ],
]

// 协议栈：L2CAP 层用一个非保留的 PSM
CASES["pdl-psm1001"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [
        [l2capU, raw([0x10, 0x01])],
        [rfcommU, raw([0x0A])],
        [obexU],
    ],
]

// 完整 MNS 记录（与客户端实现一致）
CASES["full"] = [
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [
        [l2capU, raw([0x00, 0x03])],
        [rfcommU, raw([0x0A])],
        [obexU],
    ],
    "0005 BrowseGroupList": [browseU],
    "0009 BluetoothProfileDescriptorList": [[mapProfU, raw([0x01, 0x02])]],
    "0100 ServiceName": "MAP MNS",
]

// 完整 MNS 记录 + 显式服务记录句柄
CASES["full-handle"] = [
    "0000 ServiceRecordHandle": raw([0x00, 0x00, 0x00, 0x01]),
    "0001 ServiceClassIDList": [mnsU],
    "0004 ProtocolDescriptorList": [
        [l2capU, raw([0x00, 0x03])],
        [rfcommU, raw([0x0A])],
        [obexU],
    ],
    "0005 BrowseGroupList": [browseU],
    "0009 BluetoothProfileDescriptorList": [[mapProfU, raw([0x01, 0x02])]],
    "0100 ServiceName": "MAP MNS",
]

// 完整 MNS 记录，走 plist 文本再解析回来（全程纯 Foundation 类型，排除 Swift 桥接因素）
let FULL_PLIST = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>0001 ServiceClassIDList</key>
\t<array><data>ETM=</data></array>
\t<key>0004 ProtocolDescriptorList</key>
\t<array>
\t\t<array><data>AQA=</data><dict><key>DataElementType</key><integer>1</integer><key>DataElementValue</key><data>AAM=</data></dict></array>
\t\t<array><data>AAM=</data><dict><key>DataElementType</key><integer>1</integer><key>DataElementValue</key><data>Cg==</data></dict></array>
\t\t<array><data>AAg=</data></array>
\t</array>
\t<key>0005 BrowseGroupList</key>
\t<array><data>EAI=</data></array>
\t<key>0009 BluetoothProfileDescriptorList</key>
\t<array><array><data>ETQ=</data><dict><key>DataElementType</key><integer>1</integer><key>DataElementValue</key><data>AQI=</data></dict></array></array>
\t<key>0100 ServiceName</key><string>MAP MNS</string>
</dict>
</plist>
"""

func plistDict(_ xml: String) -> [String: Any]? {
    guard let data = xml.data(using: .utf8),
          let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = obj as? [String: Any] else { return nil }
    return dict
}

let args = CommandLine.arguments
let allNames = CASES.keys.sorted() + ["full-plist"]

guard args.count >= 2 else {
    print("用法: \(args[0]) <用例名>")
    print("可用用例: \(allNames.joined(separator: " "))")
    exit(2)
}

let name = args[1]
if name == "list" {
    print(allNames.joined(separator: "\n"))
    exit(0)
}

let dict: [String: Any]
if name == "full-plist" {
    guard let d = plistDict(FULL_PLIST) else {
        print("===== 用例 full-plist =====")
        print("  构造 ✗ plist 文本解析失败")
        exit(1)
    }
    dict = d
} else if let d = CASES[name] {
    dict = d
} else {
    print("未知用例: \(name)")
    print("可用用例: \(allNames.joined(separator: " "))")
    exit(2)
}

print("===== 用例 \(name) =====")

// 第一步：本地解析，不发布
if let rec = IOBluetoothSDPServiceRecord.withServiceDictionary(dict, device: nil) {
    let attrs = rec.attributes as? [NSNumber: Any] ?? [:]
    let keys = attrs.keys.map { String(format: "%04X", $0.uint16Value) }.sorted()
    print("  解析 ✓ 属性键: \(keys.joined(separator: " "))")
    var cid: BluetoothRFCOMMChannelID = 0
    let crc = rec.getRFCOMMChannelID(&cid)
    print("  解析   RFCOMM: \(crc == kIOReturnSuccess ? "通道 \(cid)" : "读不到（rc=\(crc)）")")
    if let pdl = rec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0004)) {
        let sub = pdl.getArrayValue()?.count ?? 0
        print("  解析   PDL: 类型 \(pdl.getTypeDescriptor()) 长度 \(pdl.getSize()) 字节，子元素 \(sub) 个")
    } else {
        print("  解析   PDL: 记录里没有这一项")
    }
} else {
    print("  解析 ✗ 记录对象都没生成出来（字典格式不被接受）")
}

// 第二步：发布
if let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) {
    var handle: BluetoothSDPServiceRecordHandle = 0
    let hrc = rec.getHandle(&handle)
    var cid: BluetoothRFCOMMChannelID = 0
    let crc = rec.getRFCOMMChannelID(&cid)
    let h = hrc == kIOReturnSuccess ? "0x" + String(format: "%X", handle) : "读不到"
    let c = crc == kIOReturnSuccess ? "通道 \(cid)" : "读不到"
    print("  发布 ✓ 成功（句柄 \(h)，RFCOMM \(c)）")
    _ = rec.remove()
} else {
    print("  发布 ✗ 失败")
}
