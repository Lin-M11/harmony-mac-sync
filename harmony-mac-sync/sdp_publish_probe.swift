import Foundation
import IOBluetooth

// SDP 记录发布探测：不连手机，只试各种字典写法，看哪一种能发布成功。
// 用法: ./SDPPublishProbe

func sdpUInt16(_ v: UInt16) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data([UInt8(v >> 8), UInt8(v & 0xFF)])]
}

func sdpUInt8(_ v: UInt8) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data([v])]
}

func sdpNum(_ v: Int) -> [String: Any] {
    ["DataElementType": 1, "DataElementSize": 1, "DataElementValue": NSNumber(value: v)]
}

func sdpNum16(_ v: Int) -> [String: Any] {
    ["DataElementType": 1, "DataElementSize": 2, "DataElementValue": NSNumber(value: v)]
}

func uuid(_ v: UInt16) -> IOBluetoothSDPUUID { IOBluetoothSDPUUID(uuid16: v)! }

func tryPublish(_ name: String, _ dict: [String: Any]) {
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("✗ \(name)：发布失败")
        return
    }
    var cid: BluetoothRFCOMMChannelID = 0
    let rc = rec.getRFCOMMChannelID(&cid)
    print("✓ \(name)：发布成功，读回 RFCOMM 通道 \(cid)（rc=\(rc)）")
    _ = rec.remove()
}

// 每个用例用不同的 ServiceClassID，避免同名记录互相干扰
var classUUID: UInt16 = 0x1133
func nextClass() -> UInt16 {
    defer { classUUID += 1 }
    return classUUID
}

print("========================================")
print(" SDP 记录发布探测")
print("========================================")
print("")

let l2cap = uuid(0x0100)
let rfcomm = uuid(0x0003)
let obex = uuid(0x0008)
let browse = uuid(0x1002)
let mapProfile = uuid(0x1134)

// A 最小记录
tryPublish("A 只有 ServiceClassIDList", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
])

// B 加协议栈，数字用 DataElementType 字典
tryPublish("B 协议栈（DataElementType 字典 + Data）", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
    "0004 ProtocolDescriptorList": [
        [l2cap, sdpUInt16(0x0003)],
        [rfcomm, sdpUInt8(10)],
        [obex],
    ],
])

// C 协议栈数字用 NSNumber
tryPublish("C 协议栈（NSNumber）", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
    "0004 ProtocolDescriptorList": [
        [l2cap, sdpNum16(0x0003)],
        [rfcomm, sdpNum(10)],
        [obex],
    ],
])

// D 当前实现的完整写法
tryPublish("D 完整记录（当前实现）", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
    "0004 ProtocolDescriptorList": [
        [l2cap, sdpUInt16(0x0003)],
        [rfcomm, sdpUInt8(10)],
        [obex],
    ],
    "0005 BrowseGroupList": [browse],
    "0009 BluetoothProfileDescriptorList": [[mapProfile, sdpUInt16(0x0102)]],
    "0100 ServiceName": "MAP MNS",
    "0317 SupportedFeatures": ["DataElementType": 1, "DataElementValue": Data([0x00, 0x00, 0x00, 0x03])],
])

// E 键用 " - " 分隔
tryPublish("E 键用 \" - \" 分隔", [
    "0001 - ServiceClassIDList": [uuid(nextClass())],
    "0004 - ProtocolDescriptorList": [
        [l2cap, sdpUInt16(0x0003)],
        [rfcomm, sdpUInt8(10)],
        [obex],
    ],
    "0100 - ServiceName": "MAP MNS",
])

// F 键带 0x 前缀
tryPublish("F 键带 0x 前缀", [
    "0x0001 ServiceClassIDList": [uuid(nextClass())],
    "0x0004 ProtocolDescriptorList": [
        [l2cap, sdpUInt16(0x0003)],
        [rfcomm, sdpUInt8(10)],
        [obex],
    ],
    "0x0100 ServiceName": "MAP MNS",
])

// G 只加 Profile 描述，不带协议栈
tryPublish("G 无协议栈，只带 Profile 描述", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
    "0009 BluetoothProfileDescriptorList": [[mapProfile, sdpUInt16(0x0102)]],
    "0100 ServiceName": "MAP MNS",
])

// H 协议栈用显式 IOBluetoothSDPDataElement
if let l2capEl = IOBluetoothSDPDataElement(type: 1, sizeDescriptor: 2, size: 2, value: NSNumber(value: 3)),
   let rfcommEl = IOBluetoothSDPDataElement(type: 1, sizeDescriptor: 1, size: 1, value: NSNumber(value: 10)) {
    tryPublish("H 协议栈（显式 SDPDataElement）", [
        "0001 ServiceClassIDList": [uuid(nextClass())],
        "0004 ProtocolDescriptorList": [
            [l2cap, l2capEl],
            [rfcomm, rfcommEl],
            [obex],
        ],
    ])
} else {
    print("✗ H 构造 SDPDataElement 失败")
}

// I 指定本地持久化属性
tryPublish("I 完整记录 + LocalAttributes", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
    "0004 ProtocolDescriptorList": [
        [l2cap, sdpUInt16(0x0003)],
        [rfcomm, sdpUInt8(10)],
        [obex],
    ],
    "0100 ServiceName": "MAP MNS",
    "LocalAttributes": ["Persistent": false],
])

// J 最简：类 UUID + 服务名
tryPublish("J 类 UUID + 服务名", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
    "0100 ServiceName": "MAP MNS",
])

// K 只走 L2CAP，不含 RFCOMM 条目
tryPublish("K 协议栈只含 L2CAP + OBEX", [
    "0001 ServiceClassIDList": [uuid(nextClass())],
    "0004 ProtocolDescriptorList": [
        [l2cap, sdpUInt16(0x0003)],
        [obex],
    ],
    "0100 ServiceName": "MAP MNS",
])

print("")
print("=== 结束 ===")
