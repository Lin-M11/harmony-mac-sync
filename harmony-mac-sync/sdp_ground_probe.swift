import Foundation
import IOBluetooth

// 本机 SDP 服务器 · 地面真相探针
//
// 上一轮的观察：连着发布五次，从返回对象读回来的服务名和属性列表一模一样，
// 说明「发布之后读返回对象」这条路不代表对端能看到什么，不能当判据。
//
// 这一轮换两个可信度更高的判据：
//   一、对本机地址做一次真正的 SDP 查询 —— 这就是对端（手机）的视角
//   二、数字元素换几种规范允许的写法，看哪一种能让 0004 协议栈留下来
//
// 数字元素的写法依据 IOBluetoothSDPDataElement 头文件：
//   · 完整字典：DataElementType + DataElementSize + DataElementValue 三项齐全
//   · 简写字典：DataElementType + DataElementValue（值给 Data，长度即宽度）
//   · 显式构造：withType:sizeDescriptor:size:value:，三项自己给准
//   · 裸 NSNumber：规范里说这种会被当成 32 位无符号整数
//
// 用法：./SDPGroundProbe list
//      ./SDPGroundProbe audit
//      ./SDPGroundProbe attr-dict-size | attr-dict-plain | attr-typed | attr-number
//      ./SDPGroundProbe hold [秒数]

// MARK: - 固定 UUID

let UUID_L2CAP  = IOBluetoothSDPUUID(uuid16: 0x0100)!
let UUID_RFCOMM = IOBluetoothSDPUUID(uuid16: 0x0003)!
let UUID_OBEX   = IOBluetoothSDPUUID(uuid16: 0x0008)!
let UUID_BROWSE = IOBluetoothSDPUUID(uuid16: 0x1002)!
let UUID_MAP    = IOBluetoothSDPUUID(uuid16: 0x1134)!
let UUID_MNS    = IOBluetoothSDPUUID(uuid16: 0x1133)!

let MNS_NAME = "MAP MNS"

let PHONE_DEFAULT = "E8-1E-92-55-2D-D4"

// MARK: - 数字元素的几种写法

enum NumStyle: String {
    case dictSize  = "完整字典"
    case dictPlain = "简写字典"
    case typed     = "显式构造"
    case number    = "裸 NSNumber"
}

func bytesToUInt(_ b: [UInt8]) -> UInt32 {
    b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

func sizeDescriptor(for count: Int) -> UInt8 {
    switch count {
    case 1: return 0
    case 2: return 1
    case 4: return 2
    case 8: return 3
    case 16: return 4
    default: return 0
    }
}

func numberElement(_ bytes: [UInt8], style: NumStyle) -> Any {
    switch style {
    case .dictSize:
        return [
            "DataElementType": 1,
            "DataElementSize": bytes.count,
            "DataElementValue": Data(bytes),
        ] as [String: Any]

    case .dictPlain:
        return [
            "DataElementType": 1,
            "DataElementValue": Data(bytes),
        ] as [String: Any]

    case .typed:
        if let e = IOBluetoothSDPDataElement.withType(
            1,
            sizeDescriptor: sizeDescriptor(for: bytes.count),
            size: UInt32(bytes.count),
            value: NSNumber(value: bytesToUInt(bytes))) {
            return e
        }
        return Data(bytes)

    case .number:
        return NSNumber(value: bytesToUInt(bytes))
    }
}

// MARK: - 服务记录字典

func recordDict(style: NumStyle, name: String, channel: UInt8, includeProfile: Bool) -> [String: Any] {
    var d: [String: Any] = [
        "0001 ServiceClassIDList": [UUID_MNS],
        "0005 BrowseGroupList": [UUID_BROWSE],
        "0100 ServiceName": name,
        // 低两位：Notification Registration + Notification
        "0317 SupportedFeatures": numberElement([0x00, 0x00, 0x00, 0x03], style: style),
        "0004 ProtocolDescriptorList": [
            [UUID_L2CAP, numberElement([0x00, 0x03], style: style)],
            [UUID_RFCOMM, numberElement([channel], style: style)],
            [UUID_OBEX],
        ] as [Any],
    ]
    if includeProfile {
        d["0009 BluetoothProfileDescriptorList"] = [
            [UUID_MAP, numberElement([0x01, 0x02], style: style)],
        ] as [Any]
    }
    return d
}

// MARK: - 读数

func attrIDs(_ rec: IOBluetoothSDPServiceRecord) -> String {
    let a = rec.attributes ?? [:]
    var out: [String] = []
    for k in a.keys {
        if let n = k as? NSNumber { out.append(String(format: "%04X", n.uint16Value)) }
    }
    return out.sorted().joined(separator: ",")
}

func describe(_ rec: IOBluetoothSDPServiceRecord) -> String {
    var handle: BluetoothSDPServiceRecordHandle = 0
    let hrc = rec.getHandle(&handle)
    var cid: BluetoothRFCOMMChannelID = 0
    let crc = rec.getRFCOMMChannelID(&cid)
    let hasPDL = rec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0004)) != nil
    let hasProf = rec.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0009)) != nil

    let h = hrc == kIOReturnSuccess ? String(format: "0x%08X", handle) : "读不到"
    let c = crc == kIOReturnSuccess ? "通道 \(cid)" : "读不到"
    return "名称 \(rec.getServiceName() ?? "(无名)")  句柄 \(h)\n"
        + "       属性 [\(attrIDs(rec))]\n"
        + "       0004 \(hasPDL ? "有" : "没有")   0009 \(hasProf ? "有" : "没有")   RFCOMM \(c)"
}

/// 对本机地址做一次真正的 SDP 查询 —— 这就是手机查询我们时看到的视角
@discardableResult
func selfQuery(_ tag: String) -> Int {
    guard let addr = IOBluetoothHostController.default()?.addressAsString() else {
        print("  [\(tag)] 本机地址读不到，跳过")
        return -1
    }
    guard let dev = IOBluetoothDevice(addressString: addr) else {
        print("  [\(tag)] 本机地址 \(addr) 构不成设备对象，跳过")
        return -1
    }
    _ = dev.performSDPQuery(nil)
    var waited = 0.0
    while waited < 8.0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        waited += 0.5
        if let s = dev.services, !s.isEmpty { break }
    }
    let services = dev.services ?? []
    print("  [\(tag)] 本机地址 \(addr)  SDP 查询到 \(services.count) 条记录")
    for item in services {
        guard let r = item as? IOBluetoothSDPServiceRecord else { continue }
        let mark = r.matchesUUID16(0x1133) ? "  ← MNS" : ""
        print("     - \(describe(r))\(mark)")
    }
    return services.count
}

/// 对任意设备做一次真正的 SDP 查询。拿手机当对照组——那条路径已知能返回记录，
/// 用它来证明查询代码本身没问题，本机查询的读数才有意义。
@discardableResult
func queryDevice(_ tag: String, address: String) -> Int {
    guard let dev = IOBluetoothDevice(addressString: address) else {
        print("  [\(tag)] \(address) 构不成设备对象")
        return -1
    }
    print("  [\(tag)] \(dev.name ?? "(无名)")  \(address)")
    print("  [\(tag)] 已配对 \(dev.isPaired() ? "是" : "否")   已连接 \(dev.isConnected() ? "是" : "否")")
    _ = dev.performSDPQuery(nil)
    // 等条数稳定下来再读。只等「非空」会读到半截结果——实测刚重启完蓝牙时，
    // 第一条记录一到就返回，只看到 1 条（正常是 18 条），而且服务名全是空的。
    var last = 0
    var stable = 0
    var waited = 0.0
    while waited < 12.0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        waited += 0.5
        let n = dev.services?.count ?? 0
        if n > 0 && n == last { stable += 1 } else { stable = 0 }
        last = n
        if stable >= 4 { break }        // 连续 2 秒条数不变，认为查完了
    }
    let services = dev.services ?? []
    print("  [\(tag)] SDP 查询到 \(services.count) 条记录（等了 \(String(format: "%.1f", waited)) 秒）")
    for item in services {
        guard let r = item as? IOBluetoothSDPServiceRecord else { continue }
        let mark = r.matchesUUID16(0x1133) ? "  ← MNS" : (r.matchesUUID16(0x1132) ? "  ← MAS" : "")
        print("     - \(r.getServiceName() ?? "(无名)")\(mark)")
    }
    return services.count
}

// MARK: - 入站连接监听

final class IncomingWatcher: NSObject {
    var notifications: [IOBluetoothUserNotification] = []
    var seen: Set<BluetoothRFCOMMChannelID> = []

    func watch() {
        if let n = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(onIncoming(_:channel:))) {
            notifications.append(n)
        }
        print("  入站监听 \(notifications.isEmpty ? "✗ 注册失败" : "✓ 已注册")")
    }

    @objc func onIncoming(_ note: IOBluetoothUserNotification!, channel: IOBluetoothRFCOMMChannel!) {
        guard let ch = channel else { return }
        let id = ch.getID()
        guard !seen.contains(id) else { return }
        seen.insert(id)
        print("")
        print("  ★ 有设备连进来了：RFCOMM 通道 \(id)")
        print("")
    }
}

// MARK: - 用例

/// 发一份字典并读回，返回是否拿到对象
@discardableResult
func publishAndReport(_ tag: String, _ dict: [String: Any]) -> Bool {
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  [\(tag)] 发布 ✗ 返回空")
        return false
    }
    print("  [\(tag)] 发布 ✓")
    print("     - \(describe(rec))")
    return true
}

func caseState() {
    print("控制器与连接状态")
    let hc = IOBluetoothHostController.default()
    print("  本机地址 \(hc?.addressAsString() ?? "读不到")")
    if let p = hc?.powerState {
        print("  控制器电源 \(p.rawValue == 1 ? "开" : "关（原始值 \(p.rawValue)）")")
    }
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    let connected = paired.filter { $0.isConnected() }
    print("  已配对 \(paired.count) 台，当前连接 \(connected.count) 台")
    for d in connected {
        print("     · \(d.name ?? "?")  \(d.addressString ?? "?")")
    }
}

func caseMinimal() {
    print("最简记录：只放类 UUID + 服务名，不带协议栈")
    publishAndReport("最简", [
        "0001 ServiceClassIDList": [UUID_MNS],
        "0100 ServiceName": MNS_NAME,
    ])
}

func caseControl128() {
    print("对照：换一个从未用过的 128 位类 UUID，同样不带协议栈")
    let bytes = (0..<16).map { UInt8(0xA0 + $0) }
    let u = IOBluetoothSDPUUID(data: Data(bytes))
    publishAndReport("对照", [
        "0001 ServiceClassIDList": [u],
        "0100 ServiceName": "CONTROL-128",
    ])
}

func caseAudit() {
    print("只查不发：本机 SDP 服务器现在存着什么")
    selfQuery("审计")
}

func casePhone() {
    print("对照组：对手机做 SDP 查询。这条路径已知能返回记录")
    let addr = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : PHONE_DEFAULT
    queryDevice("手机", address: addr)
}

/// 一个进程里把「查本机 → 发布 → 撤回」串起来，让每一步的读数可比。
/// 拆成多个进程跑的时候，记录会随进程退出消失，前后读数对不上。
/// 对手机的查询放在最后：远端查询会占住协议栈，发布排在它后面容易拿不到对象。
func caseTruth() {
    let addr = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : PHONE_DEFAULT

    print("[1] 发布前，查本机")
    let before = selfQuery("发布前")

    print("")
    print("[2] 两种数字写法各发一份，各自读回并用 remove() 配对")
    var results: [(String, String)] = []      // (标签, 结论)
    for (style, label) in [(NumStyle.dictSize, "完整字典"), (NumStyle.dictPlain, "简写字典")] {
        let dict = recordDict(style: style, name: "\(MNS_NAME) \(label)", channel: 10, includeProfile: true)
        guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
            print("  [\(label)] 发布 ✗ 返回空")
            results.append((label, "发布返回空"))
            continue
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        print("  [\(label)] 发布 ✓")
        print("     - \(describe(rec))")

        let rc1 = rec.remove()
        let rc2 = rec.remove()
        let ok1 = rc1 == kIOReturnSuccess
        let ok2 = rc2 == kIOReturnSuccess
        print("     remove() 第一次 \(rc1)\(ok1 ? "（成功）" : "（未成功）")，第二次 \(rc2)\(ok2 ? "（成功）" : "（未成功）")")
        results.append((label, ok1 && !ok2 ? "remove 配对成立 → 记录确实挂上去过" : "remove 配对不成立"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    print("")
    print("[3] 对手机做 SDP 查询（对照组，证明查询代码本身没问题）")
    let phoneCount = queryDevice("手机", address: addr)

    print("")
    print("[4] 小结")
    print("  本机查询：发布前 \(before) 条；手机查询 \(phoneCount) 条")
    for (label, verdict) in results {
        print("  \(label)：\(verdict)")
    }
    if phoneCount > 0 && before == 0 {
        print("  → 查询代码是通的（手机能查到），但本机查询读不到本机 SDP 数据库")
    }
}

func caseAttr(style: NumStyle) {
    print("数字元素写法：\(style.rawValue)")
    let dict = recordDict(style: style, name: MNS_NAME, channel: 10, includeProfile: true)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
        print("  发布 ✗ 返回空")
        return
    }
    print("  发布 ✓ 返回对象读数：")
    print("     - \(describe(rec))")
    print("  —— 换成本机 SDP 查询（对端视角）——")
    selfQuery("查询")
    _ = rec.remove()
}

func caseHold(seconds: Double) {
    print("三种写法各发一条记录，各自占一个通道，一起保持 \(Int(seconds)) 秒")

    let plans: [(NumStyle, UInt8)] = [(.dictSize, 10), (.typed, 11), (.number, 12)]
    var records: [IOBluetoothSDPServiceRecord] = []

    for (style, channel) in plans {
        let dict = recordDict(style: style, name: "\(MNS_NAME) \(style.rawValue)",
                              channel: channel, includeProfile: true)
        if let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) {
            records.append(rec)
            var cid: BluetoothRFCOMMChannelID = 0
            let crc = rec.getRFCOMMChannelID(&cid)
            print("  ✓ \(style.rawValue) 期望通道 \(channel)，读回 \(crc == kIOReturnSuccess ? String(cid) : "读不到")")
        } else {
            print("  ✗ \(style.rawValue) 发布返回空")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    }

    print("")
    print("  —— 本机 SDP 查询（对端视角）——")
    selfQuery("查询")

    print("")
    print("  >>> 接下来 \(Int(seconds)) 秒里，请在手机上确认蓝牙已连接，并且往手机发一条短信 <<<")
    print("  >>> 手机若能主动连过来，上面会打印「有设备连进来了」 <<<")
    print("")

    let watcher = IncomingWatcher()
    watcher.watch()

    var left = seconds
    while left > 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        left -= 1
        if Int(left) % 15 == 0 && left > 0 {
            print("  … 还剩 \(Int(left)) 秒（已记录入站连接 \(watcher.seen.count) 次）")
        }
    }

    for rec in records { _ = rec.remove() }
    print("  记录已收回")
}

// MARK: - 入口

let ALL = ["state", "audit", "phone", "truth", "minimal", "control-128",
           "attr-dict-size", "attr-dict-plain", "attr-typed", "attr-number", "hold"]

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: \(args[0]) <用例名> [秒数]")
    print("可用用例: \(ALL.joined(separator: " "))")
    exit(2)
}

let name = args[1]
if name == "list" {
    print(ALL.joined(separator: "\n"))
    exit(0)
}

print("===== 用例 \(name) =====")

switch name {
case "state":            caseState()
case "audit":            caseAudit()
case "phone":            casePhone()
case "truth":            caseTruth()
case "minimal":          caseMinimal()
case "control-128":      caseControl128()
case "attr-dict-size":   caseAttr(style: .dictSize)
case "attr-dict-plain":  caseAttr(style: .dictPlain)
case "attr-typed":       caseAttr(style: .typed)
case "attr-number":      caseAttr(style: .number)
case "hold":
    let secs = args.count >= 3 ? (Double(args[2]) ?? 150) : 150
    caseHold(seconds: secs)
default:
    print("未知用例: \(name)")
    print("可用用例: \(ALL.joined(separator: " "))")
    exit(2)
}

print("")
