import Foundation
import IOBluetooth

// SDP 发布状态探测
//
// 上一轮的结果里，除第一个用例外全部「发布成功」，而且句柄都是同一个值 0x4F491133，
// 属性却读出来是空的。这不像发布成功，更像拿到了一条已经存在的记录。
// 这一轮不试新写法，只用几个硬指标判断「发布到底有没有真的建出记录」：
//
//   1) getServiceName()        —— 读属性 0x0100。能读回我们写的名字，说明属性确实进去了
//   2) attributes 原始内容     —— 直接打印，不经过 Swift 字典转换，排除我这边读法的问题
//   3) remove() 的返回值       —— 文档：成功移除返回 kIOReturnSuccess。记录不存在时不会成功
//   4) 同进程发布两次的句柄对比 —— 句柄不同 = 真建了两条；相同 = 拿到的是同一条
//   5) 换一个从未用过的 128 位类 UUID —— 排除「0x1133 已有残留记录」这个可能
//   6) dlsym 找 IOBluetoothRemoveServiceWithRecordHandle —— 按句柄删，绕过 rec.remove()
//
// 用法: ./SDPStateProbe <用例名>
//       ./SDPStateProbe list

let l2capU   = IOBluetoothSDPUUID(uuid16: 0x0100)!
let rfcommU  = IOBluetoothSDPUUID(uuid16: 0x0003)!
let obexU    = IOBluetoothSDPUUID(uuid16: 0x0008)!
let browseU  = IOBluetoothSDPUUID(uuid16: 0x1002)!
let mapProfU = IOBluetoothSDPUUID(uuid16: 0x1134)!
let mnsU     = IOBluetoothSDPUUID(uuid16: 0x1133)!

func raw(_ bytes: [UInt8]) -> [String: Any] {
    ["DataElementType": 1, "DataElementValue": Data(bytes)]
}

func mnsDict(classUUID: IOBluetoothSDPUUID, channel: UInt8 = 0x0A) -> [String: Any] {
    [
        "0001 ServiceClassIDList": [classUUID],
        "0004 ProtocolDescriptorList": [
            [l2capU, raw([0x00, 0x03])],
            [rfcommU, raw([channel])],
            [obexU],
        ],
        "0005 BrowseGroupList": [browseU],
        "0009 BluetoothProfileDescriptorList": [[mapProfU, raw([0x01, 0x02])]],
        "0100 ServiceName": "MAP MNS",
    ]
}

func dump(_ tag: String, _ rec: IOBluetoothSDPServiceRecord) {
    var handle: BluetoothSDPServiceRecordHandle = 0
    let hrc = rec.getHandle(&handle)
    let h = hrc == kIOReturnSuccess ? "0x" + String(format: "%X", handle) : "读不到（rc=\(hrc)）"

    var cid: BluetoothRFCOMMChannelID = 0
    let crc = rec.getRFCOMMChannelID(&cid)
    let c = crc == kIOReturnSuccess ? "通道 \(cid)" : "读不到（rc=\(crc)）"

    let name = rec.getServiceName() ?? "(nil)"

    let attrs = rec.attributes
    let attrText: String
    if let a = attrs {
        let s = String(describing: a)
        attrText = a.isEmpty ? "空字典" : String(s.prefix(400))
    } else {
        attrText = "nil"
    }

    print("  \(tag) 句柄: \(h)")
    print("  \(tag) 服务名: \(name)")
    print("  \(tag) RFCOMM: \(c)")
    print("  \(tag) attributes: \(attrText)")
}

func tryRemove(_ tag: String, _ rec: IOBluetoothSDPServiceRecord) {
    let rc = rec.remove()
    let ok = rc == kIOReturnSuccess
    print("  \(tag) remove() 返回 \(rc)\(ok ? "（成功）" : "（未成功）")")
}

let privateUUID = IOBluetoothSDPUUID(data: Data([
    0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x12, 0x34,
    0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,
]))

var CASES: [String] = []

func caseAttr() {
    print("本地解析（withServiceDictionary，不发布）")
    let dict = mnsDict(classUUID: mnsU)
    if let rec = IOBluetoothSDPServiceRecord.withServiceDictionary(dict, device: nil) {
        dump("解析", rec)
    } else {
        print("  解析 ✗ 返回 nil")
    }
}

func casePubOnce() {
    print("发布 MNS 完整记录（类 UUID 0x1133）")
    let dict = mnsDict(classUUID: mnsU)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    print("  发布 ✓ 返回了对象")
    dump("发布", rec)
    tryRemove("发布", rec)
}

func casePubTwice() {
    print("同一个进程里，用同一份字典发布两次")
    let dict = mnsDict(classUUID: mnsU)

    var handles: [String] = []
    var recs: [IOBluetoothSDPServiceRecord] = []

    for i in 1...2 {
        guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
            print("  第 \(i) 次 ✗ 返回 nil")
            continue
        }
        var handle: BluetoothSDPServiceRecordHandle = 0
        let hrc = rec.getHandle(&handle)
        let h = hrc == kIOReturnSuccess ? "0x" + String(format: "%X", handle) : "读不到"
        handles.append(h)
        recs.append(rec)
        print("  第 \(i) 次 ✓ 句柄 \(h)，服务名 \(rec.getServiceName() ?? "(nil)")")
    }

    if handles.count == 2 {
        print("  两次句柄\(handles[0] == handles[1] ? "相同 → 拿到的是同一条记录" : "不同 → 确实建了两条")")
    }
    for (i, rec) in recs.enumerated() {
        tryRemove("第 \(i + 1) 次", rec)
    }
}

func casePub128() {
    print("发布一条从未用过的 128 位类 UUID 记录")
    let dict = mnsDict(classUUID: privateUUID)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    print("  发布 ✓ 返回了对象")
    dump("发布", rec)
    tryRemove("发布", rec)
}

func casePubProd() {
    print("发布客户端实际用的那份字典（比 full 多一个 0317 SupportedFeatures）")
    var dict = mnsDict(classUUID: mnsU)
    dict["0317 SupportedFeatures"] = ["DataElementType": 1, "DataElementValue": Data([0x00, 0x00, 0x00, 0x03])]
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil")
        return
    }
    print("  发布 ✓ 返回了对象")
    dump("发布", rec)
    tryRemove("发布", rec)
}

func caseLocal() {
    print("尝试拿本机设备对象")
    if let dev = IOBluetoothDevice(addressString: nil) {
        print("  本机对象: 名称 \(dev.name ?? "(nil)")  地址 \(dev.addressString ?? "(nil)")")
        _ = dev.performSDPQuery(nil)
        var waited = 0.0
        while waited < 6.0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            waited += 0.5
            if let s = dev.services, !s.isEmpty { break }
        }
        if let s = dev.services, !s.isEmpty {
            print("  ✓ 本机 SDP 记录 \(s.count) 条")
            for item in s {
                guard let r = item as? IOBluetoothSDPServiceRecord else { continue }
                print("     - \(r.getServiceName() ?? "(无名)")  MNS=\(r.matchesUUID16(0x1133))  MAS=\(r.matchesUUID16(0x1132))")
            }
        } else {
            print("  ✗ 本机 SDP 记录读不到")
        }
    } else {
        print("  ✗ addressString: nil 拿不到对象")
    }
}

func caseCapi() {
    print("找 C 层发布接口 IOBluetoothAddServiceDict")
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
    _ = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)

    let addSym = dlsym(defaultHandle, "IOBluetoothAddServiceDict")
    let rmSym = dlsym(defaultHandle, "IOBluetoothRemoveServiceWithRecordHandle")
    print("  IOBluetoothAddServiceDict: \(addSym == nil ? "不存在" : "存在")")
    print("  IOBluetoothRemoveServiceWithRecordHandle: \(rmSym == nil ? "不存在" : "存在")")

    guard let a = addSym else {
        print("  没有 C 层发布接口，跳过")
        return
    }

    typealias AddFn = @convention(c) (CFDictionary, UnsafeMutablePointer<BluetoothSDPServiceRecordHandle>) -> IOReturn
    let fn = unsafeBitCast(a, to: AddFn.self)

    let dict = mnsDict(classUUID: mnsU) as CFDictionary
    var handle: BluetoothSDPServiceRecordHandle = 0
    let rc = fn(dict, &handle)
    print("  IOBluetoothAddServiceDict 返回 \(rc)\(rc == kIOReturnSuccess ? "（成功）" : "（未成功）")")
    guard rc == kIOReturnSuccess else { return }
    print("  句柄 0x" + String(format: "%X", handle))

    if let r = rmSym {
        typealias RemoveFn = @convention(c) (BluetoothSDPServiceRecordHandle) -> IOReturn
        let rfn = unsafeBitCast(r, to: RemoveFn.self)
        let rrc = rfn(handle)
        print("  按句柄删除返回 \(rrc)\(rrc == kIOReturnSuccess ? "（成功）" : "（未成功）")")
    }
}

func caseDlsym() {
    print("找 IOBluetoothRemoveServiceWithRecordHandle")
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
    var sym = dlsym(defaultHandle, "IOBluetoothRemoveServiceWithRecordHandle")
    if sym == nil {
        _ = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
        sym = dlsym(defaultHandle, "IOBluetoothRemoveServiceWithRecordHandle")
    }
    guard let s = sym else {
        print("  ✗ 符号不存在")
        return
    }
    print("  ✓ 符号存在: \(s)")
    typealias RemoveFn = @convention(c) (BluetoothSDPServiceRecordHandle) -> IOReturn
    let fn = unsafeBitCast(s, to: RemoveFn.self)

    let dict = mnsDict(classUUID: mnsU)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回 nil，无法继续")
        return
    }
    var handle: BluetoothSDPServiceRecordHandle = 0
    let hrc = rec.getHandle(&handle)
    guard hrc == kIOReturnSuccess else {
        print("  句柄读不到，无法继续")
        return
    }
    print("  发布 ✓ 句柄 0x\(String(format: "%X", handle))")
    let rc = fn(handle)
    print("  按句柄删除返回 \(rc)\(rc == kIOReturnSuccess ? "（成功）" : "（未成功）")")
    let rc2 = fn(handle)
    print("  再删一次返回 \(rc2)（已删掉时应当不成功，可作对照）")
}

let ALL: [(String, () -> Void)] = [
    ("attr", caseAttr),
    ("pub-once", casePubOnce),
    ("pub-twice", casePubTwice),
    ("pub-128", casePub128),
    ("pub-prod", casePubProd),
    ("local", caseLocal),
    ("capi", caseCapi),
    ("dlsym", caseDlsym),
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
