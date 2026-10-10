import Foundation
import IOBluetooth

// SDP 记录定论探针
//
// 已知事实：发布后读回来的属性里，0004 ProtocolDescriptorList 与 0009
// BluetoothProfileDescriptorList 都不见了；但 getServiceName 能读回我们写的名字、
// remove() 也返回成功，说明发布本身有落到本机 SDP 服务器。
//
// 这一轮只回答三个问题，不再试新花样：
//   Q1 是不是「读太早」—— 发布是异步的，隔几秒再读一次，看属性会不会补齐
//   Q2 是不是「读到旧记录」—— 换一个服务名再发一次，看名字会不会跟着变
//   Q3 是不是「读法的问题」—— 绕过 rec.attributes，改成本机 SDP 查询，直接看服务端存了什么
//
// 用法: ./SDPFinalProbe <用例名>
//       ./SDPFinalProbe list

let l2capU   = IOBluetoothSDPUUID(uuid16: 0x0100)!
let rfcommU  = IOBluetoothSDPUUID(uuid16: 0x0003)!
let obexU    = IOBluetoothSDPUUID(uuid16: 0x0008)!
let browseU  = IOBluetoothSDPUUID(uuid16: 0x1002)!
let mapProfU = IOBluetoothSDPUUID(uuid16: 0x1134)!
let mnsU     = IOBluetoothSDPUUID(uuid16: 0x1133)!

/// 数字元素，值给原始字节（网络序），元素宽度取自字节数
func raw(_ bytes: [UInt8]) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data(bytes)]
}

enum PdlStyle { case nested, uuidOnly, elementTree }

func serviceDict(name: String, pdl: PdlStyle, includeProfile: Bool) -> [String: Any] {
    var d: [String: Any] = [
        "0001 ServiceClassIDList": [mnsU],
        "0005 BrowseGroupList": [browseU],
        "0100 ServiceName": name,
        "0317 SupportedFeatures": raw([0x00, 0x00, 0x00, 0x03]),
    ]

    switch pdl {
    case .nested:
        d["0004 ProtocolDescriptorList"] = [
            [l2capU, raw([0x00, 0x03])],
            [rfcommU, raw([0x0A])],
            [obexU],
        ]
    case .uuidOnly:
        d["0004 ProtocolDescriptorList"] = [[l2capU], [rfcommU], [obexU]]
    case .elementTree:
        if let e = elementTree() { d["0004 ProtocolDescriptorList"] = e }
    }

    if includeProfile {
        d["0009 BluetoothProfileDescriptorList"] = [[mapProfU, raw([0x01, 0x02])]]
    }
    return d
}

/// 协议栈整棵树都用 IOBluetoothSDPDataElement 自己搭，字典一个都不放
func elementTree() -> IOBluetoothSDPDataElement? {
    func seq(_ items: [Any]) -> IOBluetoothSDPDataElement? {
        IOBluetoothSDPDataElement.withElementValue(items as NSObject)
    }
    guard let l2capEntry = seq([l2capU, Data([0x00, 0x03])]),
          let rfcommEntry = seq([rfcommU, Data([0x0A])]),
          let obexEntry = seq([obexU]) else { return nil }
    return seq([l2capEntry, rfcommEntry, obexEntry])
}

func attrIDs(_ rec: IOBluetoothSDPServiceRecord) -> String {
    let a = rec.attributes ?? [:]
    var out: [String] = []
    for k in a.keys {
        if let n = k as? NSNumber {
            out.append(String(format: "%04X", n.uint16Value))
        } else if let s = k as? String {
            out.append("文本:" + String(s.prefix(8)))
        } else {
            out.append(String(describing: k))
        }
    }
    return out.sorted().joined(separator: " ")
}

/// 读一遍记录里我们关心的几项
func inspect(_ tag: String, _ rec: IOBluetoothSDPServiceRecord) {
    let has4 = rec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0004)) != nil
    let has9 = rec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0009)) != nil
    let has17 = rec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0317)) != nil

    var cid: BluetoothRFCOMMChannelID = 0
    let crc = rec.getRFCOMMChannelID(&cid)

    print("  [\(tag)] 服务名 \(rec.getServiceName() ?? "(nil)")")
    print("  [\(tag)] 属性 ID: \(attrIDs(rec))")
    print("  [\(tag)] 0004 \(has4 ? "有" : "没有")   0009 \(has9 ? "有" : "没有")   0317 \(has17 ? "有" : "没有")")
    print("  [\(tag)] RFCOMM: \(crc == kIOReturnSuccess ? "通道 \(cid)" : "读不到（rc=\(crc)）")")
}

/// 停一会儿，让本机 SDP 服务器把异步的部分处理完
func settle(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// 本机蓝牙地址
func localAddress() -> String? {
    IOBluetoothHostController.default()?.addressAsString()
}

/// 直接问本机 SDP 服务器：查自己的服务记录。这是最接近「手机能看到什么」的视角。
func selfQuery() {
    guard let addr = localAddress() else {
        print("  本机地址读不到，跳过")
        return
    }
    print("  本机地址 \(addr)")
    guard let dev = IOBluetoothDevice(addressString: addr) else {
        print("  本机设备对象构造失败，跳过")
        return
    }
    _ = dev.performSDPQuery(nil)
    var waited = 0.0
    while waited < 8.0 {
        settle(0.5)
        waited += 0.5
        if let s = dev.services, !s.isEmpty { break }
    }
    guard let services = dev.services, !services.isEmpty else {
        print("  本机 SDP 查询没返回记录")
        return
    }
    print("  本机 SDP 记录 \(services.count) 条")
    for item in services {
        guard let r = item as? IOBluetoothSDPServiceRecord else { continue }
        let isMns = r.matchesUUID16(0x1133)
        let mark = isMns ? "  ← MNS" : ""
        print("     - \(r.getServiceName() ?? "(无名)")  属性 [\(attrIDs(r))]\(mark)")
        if isMns { inspect("本机查询", r) }
    }
}

// MARK: 用例

func caseNow() {
    print("发布客户端那份字典，分别在 0 秒 / 2 秒 / 5 秒后各读一次")
    let dict = serviceDict(name: "MAP MNS", pdl: .nested, includeProfile: true)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    inspect("0 秒", rec)
    settle(2)
    inspect("2 秒", rec)
    settle(3)
    inspect("5 秒", rec)
    let rc = rec.remove()
    print("  remove() 返回 \(rc)\(rc == kIOReturnSuccess ? "（成功）" : "（未成功）")")
}

func caseNameA() {
    print("发布一份服务名为 MNS-A 的记录，看读回来的是不是这个名字")
    let dict = serviceDict(name: "MNS-A", pdl: .nested, includeProfile: true)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    settle(2)
    inspect("2 秒", rec)
    _ = rec.remove()
}

func caseNameB() {
    print("紧接着（另一个进程）发布服务名为 MNS-B 的记录，看名字会不会跟着换")
    let dict = serviceDict(name: "MNS-B", pdl: .nested, includeProfile: true)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    settle(2)
    inspect("2 秒", rec)
    _ = rec.remove()
}

func caseMinimal() {
    print("只放 0001 + 0004 两项，看协议栈能不能单独存活")
    var dict: [String: Any] = [
        "0001 ServiceClassIDList": [mnsU],
        "0100 ServiceName": "MNS-MIN",
    ]
    dict["0004 ProtocolDescriptorList"] = [
        [l2capU, raw([0x00, 0x03])],
        [rfcommU, raw([0x0A])],
        [obexU],
    ]
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    settle(2)
    inspect("2 秒", rec)
    _ = rec.remove()
}

func caseUuidOnly() {
    print("协议栈每层只放 UUID，不带任何参数")
    let dict = serviceDict(name: "MNS-U", pdl: .uuidOnly, includeProfile: false)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    settle(2)
    inspect("2 秒", rec)
    _ = rec.remove()
}

func caseElementTree() {
    print("协议栈整棵树用 IOBluetoothSDPDataElement 搭")
    let dict = serviceDict(name: "MNS-E", pdl: .elementTree, includeProfile: true)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    settle(2)
    inspect("2 秒", rec)
    _ = rec.remove()
}

func caseSelfQuery() {
    print("发布后再问本机 SDP 服务器，看服务端实际存了什么")
    let dict = serviceDict(name: "MAP MNS", pdl: .nested, includeProfile: true)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    settle(2)
    inspect("发布对象", rec)
    print("  —— 换成本机 SDP 查询 ——")
    selfQuery()
    _ = rec.remove()
}

let ALL: [(String, () -> Void)] = [
    ("now", caseNow),
    ("name-a", caseNameA),
    ("name-b", caseNameB),
    ("minimal", caseMinimal),
    ("uuid-only", caseUuidOnly),
    ("element-tree", caseElementTree),
    ("self-query", caseSelfQuery),
]

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: \(args[0]) <用例名>")
    print("可用用例: " + ALL.map { $0.0 }.joined(separator: " "))
    exit(2)
}

let name = args[1]
if name == "list" {
    print(ALL.map { $0.0 }.joined(separator: "\n"))
    exit(0)
}

guard let hit = ALL.first(where: { $0.0 == name }) else {
    print("未知用例: \(name)")
    print("可用用例: " + ALL.map { $0.0 }.joined(separator: " "))
    exit(2)
}

print("===== 用例 \(name) =====")
hit.1()
print("")
