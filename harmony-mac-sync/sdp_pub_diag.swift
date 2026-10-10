import Foundation
import IOBluetooth

// 本机 SDP 服务器能不能放下记录 —— 判定探针
//
// 背景：MAP 的 MNS 记录发布一直返回空。字典格式已按头文件核对过：
// 键名只要「十六进制 ID + 空格 + 后缀」就合法，数字元素用完整字典或简写字典都合法。
// 所以返回空不像是写法问题。这个探针换一个问法：这台机器上，这个进程能不能放进任何记录。
//
// 判读方式：
//   · 串口服务（0x1101）是对照组。系统文档里的示例就是它。
//     如果连它都返回空，说明问题不在 MAP 的字典上，而在发布这条路上。
//   · MAP MNS 有几种收敛写法，逐个试。
//   · Objective-C 层与 C 层各试一遍，看两边是否一致。
//   · 放进去的记录用 remove() 连删两次做配对：在时成功、删掉后不成功，说明记录确实挂上去过。
//
// 用法: ./SDPPubDiag <用例名>

let l2capU   = IOBluetoothSDPUUID(uuid16: 0x0100)!
let rfcommU  = IOBluetoothSDPUUID(uuid16: 0x0003)!
let obexU    = IOBluetoothSDPUUID(uuid16: 0x0008)!
let browseU  = IOBluetoothSDPUUID(uuid16: 0x1002)!
let sppU     = IOBluetoothSDPUUID(uuid16: 0x1101)!
let mapProfU = IOBluetoothSDPUUID(uuid16: 0x1134)!
let mnsU     = IOBluetoothSDPUUID(uuid16: 0x1133)!

let CH: UInt8 = 30

/// 数字元素：只给类型，值用数据，宽度由数据长度定
func numData(_ bytes: [UInt8]) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data(bytes)]
}

/// 数字元素：类型、宽度、值三件都给
func numFull(_ value: Int, size: Int) -> [String: Any] {
    ["DataElementType": 1, "DataElementSize": size, "DataElementValue": value]
}

/// 串口服务，键名带后缀，数字用数值（贴近系统文档示例）
func sppNumDict() -> [String: Any] {
    [
        "0001 - ServiceClassIDList": [sppU],
        "0004 - ProtocolDescriptorList": [
            [l2capU, numFull(3, size: 2)],
            [rfcommU, numFull(Int(CH), size: 1)],
        ],
        "0005 - BrowseGroupList": [browseU],
        "0100 - ServiceName": "SPP 对照组",
    ]
}

/// 串口服务，键名不带后缀，数字用数据
func sppDataDict() -> [String: Any] {
    [
        "0001 ServiceClassIDList": [sppU],
        "0004 ProtocolDescriptorList": [
            [l2capU, numData([0x00, 0x03])],
            [rfcommU, numData([CH])],
        ],
        "0005 BrowseGroupList": [browseU],
        "0100 ServiceName": "SPP 对照组",
    ]
}

/// MAP MNS，当前生产程序用的那份
func mnsDict() -> [String: Any] {
    [
        "0001 ServiceClassIDList": [mnsU],
        "0004 ProtocolDescriptorList": [
            [l2capU, numData([0x00, 0x03])],
            [rfcommU, numData([CH])],
            [obexU],
        ],
        "0005 BrowseGroupList": [browseU],
        "0009 BluetoothProfileDescriptorList": [[mapProfU, numData([0x01, 0x02])]],
        "0100 ServiceName": "MAP MNS",
    ]
}

/// MAP MNS，只留类 UUID 与协议列表
func mnsMinDict() -> [String: Any] {
    [
        "0001 ServiceClassIDList": [mnsU],
        "0004 ProtocolDescriptorList": [
            [l2capU, numData([0x00, 0x03])],
            [rfcommU, numData([CH])],
            [obexU],
        ],
    ]
}

/// MAP MNS，协议列表只留 L2CAP
func mnsL2capDict() -> [String: Any] {
    [
        "0001 ServiceClassIDList": [mnsU],
        "0004 ProtocolDescriptorList": [[l2capU, numData([0x00, 0x03])]],
        "0005 BrowseGroupList": [browseU],
    ]
}

/// MAP MNS，带一个本地属性，声明记录要留存
func mnsPersistDict() -> [String: Any] {
    var d = mnsDict()
    d["LocalAttributes"] = ["Persistent": true]
    return d
}

func report(_ tag: String, _ rec: IOBluetoothSDPServiceRecord) {
    var handle: BluetoothSDPServiceRecordHandle = 0
    let hrc = rec.getHandle(&handle)
    let h = hrc == kIOReturnSuccess ? "0x" + String(format: "%X", handle) : "读不到（rc=\(hrc)）"

    var cid: BluetoothRFCOMMChannelID = 0
    let crc = rec.getRFCOMMChannelID(&cid)
    let c = crc == kIOReturnSuccess ? "通道 \(cid)" : "读不到（rc=\(crc)）"

    print("  [\(tag)] 句柄 \(h)")
    print("  [\(tag)] 服务名 \(rec.getServiceName() ?? "(nil)")")
    print("  [\(tag)] RFCOMM \(c)")
    if let a = rec.attributes {
        let s = String(describing: a)
        print("  [\(tag)] 属性 \(a.isEmpty ? "空" : String(s.prefix(300)))")
    } else {
        print("  [\(tag)] 属性 nil")
    }

    let rc1 = rec.remove()
    let rc2 = rec.remove()
    let ok1 = rc1 == kIOReturnSuccess
    let ok2 = rc2 == kIOReturnSuccess
    print("  [\(tag)] remove 第一次 \(rc1)\(ok1 ? "（成功）" : "（未成功）")，第二次 \(rc2)\(ok2 ? "（成功）" : "（未成功）")")
    print("  [\(tag)] 配对\(ok1 && !ok2 ? "成立 → 记录确实挂上去过" : "不成立")")
}

func publish(_ tag: String, _ dict: [String: Any]) {
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  [\(tag)] 发布 ✗ 返回空")
        return
    }
    print("  [\(tag)] 发布 ✓ 拿到对象")
    report(tag, rec)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
}

// MARK: - C 层

typealias AddFn = @convention(c) (CFDictionary, UnsafeMutablePointer<BluetoothSDPServiceRecordHandle>) -> IOReturn
typealias RemoveFn = @convention(c) (BluetoothSDPServiceRecordHandle) -> IOReturn

func loadCapi() -> (AddFn, RemoveFn)? {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    _ = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
    guard let a = dlsym(rtldDefault, "IOBluetoothAddServiceDict"),
          let r = dlsym(rtldDefault, "IOBluetoothRemoveServiceWithRecordHandle") else {
        return nil
    }
    return (unsafeBitCast(a, to: AddFn.self), unsafeBitCast(r, to: RemoveFn.self))
}

func capiPublish(_ tag: String, _ dict: [String: Any]) {
    guard let (add, rm) = loadCapi() else {
        print("  [\(tag)] C 层符号不存在")
        return
    }
    var handle: BluetoothSDPServiceRecordHandle = 0
    let rc = add(dict as CFDictionary, &handle)
    print("  [\(tag)] IOBluetoothAddServiceDict 返回 \(rc)\(rc == kIOReturnSuccess ? "（成功）" : "（未成功）")")
    guard rc == kIOReturnSuccess else { return }
    print("  [\(tag)] 句柄 0x" + String(format: "%X", handle))
    let r1 = rm(handle)
    let r2 = rm(handle)
    print("  [\(tag)] 按句柄删第一次 \(r1)\(r1 == kIOReturnSuccess ? "（成功）" : "（未成功）")，第二次 \(r2)\(r2 == kIOReturnSuccess ? "（成功）" : "（未成功）")")
}

// MARK: - 用例

func caseBundle() {
    print("进程身份与蓝牙电源状态")
    print("  Bundle ID   : \(Bundle.main.bundleIdentifier ?? "(nil)")")
    print("  Bundle 路径 : \(Bundle.main.bundlePath)")
    print("  用途说明    : \(Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String ?? "(没有)")")
    print("  进程号      : \(getpid())")
    print("  C 层符号    : \(loadCapi() == nil ? "不齐" : "齐全")")
}

func caseParse() {
    print("本地解析，不发布")
    let items: [(String, [String: Any])] = [
        ("串口·数值", sppNumDict()),
        ("串口·数据", sppDataDict()),
        ("MAP MNS", mnsDict()),
    ]
    for (label, d) in items {
        guard let rec = IOBluetoothSDPServiceRecord.withServiceDictionary(d, device: nil) else {
            print("  [\(label)] 解析 ✗ 返回空")
            continue
        }
        var handle: BluetoothSDPServiceRecordHandle = 0
        let hrc = rec.getHandle(&handle)
        let h = hrc == kIOReturnSuccess ? "0x" + String(format: "%X", handle) : "读不到"
        var cid: BluetoothRFCOMMChannelID = 0
        let crc = rec.getRFCOMMChannelID(&cid)
        let c = crc == kIOReturnSuccess ? "\(cid)" : "读不到"
        let attrs = rec.attributes
        let count = attrs?.count ?? -1
        print("  [\(label)] 解析 ✓ 句柄 \(h) 服务名 \(rec.getServiceName() ?? "(nil)") RFCOMM \(c) 属性条数 \(count)")
        if let a = attrs {
            print("       属性原文: \(String(String(describing: a).prefix(700)))")
        }
    }
}

func caseSppNum()  { print("对照组：串口服务，键名带后缀、数字用数值"); publish("串口·数值", sppNumDict()) }
func caseSppData() { print("对照组：串口服务，键名不带后缀、数字用数据"); publish("串口·数据", sppDataDict()) }
func caseMnsOurs() { print("MAP MNS，当前写法"); publish("MNS·当前", mnsDict()) }
func caseMnsMin()  { print("MAP MNS，只留 0001 与 0004"); publish("MNS·精简", mnsMinDict()) }
func caseMnsL2cap(){ print("MAP MNS，0004 只留 L2CAP"); publish("MNS·L2CAP", mnsL2capDict()) }
func caseMnsPersist() { print("MAP MNS，带本地属性 Persistent"); publish("MNS·留存", mnsPersistDict()) }
func caseCapiSpp() { print("C 层：串口服务"); capiPublish("C·串口", sppDataDict()) }
func caseCapiMns() { print("C 层：MAP MNS"); capiPublish("C·MNS", mnsDict()) }

let ALL: [(String, () -> Void)] = [
    ("bundle", caseBundle),
    ("parse", caseParse),
    ("spp-num", caseSppNum),
    ("spp-data", caseSppData),
    ("mns-ours", caseMnsOurs),
    ("mns-min", caseMnsMin),
    ("mns-l2cap", caseMnsL2cap),
    ("mns-persist", caseMnsPersist),
    ("capi-spp", caseCapiSpp),
    ("capi-mns", caseCapiMns),
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
