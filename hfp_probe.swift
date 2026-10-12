// HFP 通话探针
//
// 走蓝牙 HFP，让 Mac 当免提端（HF）、手机当音频网关（AG）。用来确认三件事：
//   1. 信令通道能否建立，来电号码能否收到
//   2. SCO 音频通道能否建立
//   3. 通话音频落到哪个系统音频设备上 —— 也就是「用连着 Mac 的耳机通话」是否成立
//
// 每步之间打一份音频设备快照（默认输入/输出、设备清单、传输类型），
// 对比通话前后的差异，就能看出系统把 SCO 音频接到了哪里。
//
// 用法：由 run_hfp_probe.command 调用。不要直接跑，蓝牙权限判定要靠终端。

import Foundation
import IOBluetooth
import CoreAudio

let PHONE_ADDR = "E8-1E-92-55-2D-D4"
let LOG_PATH = "/tmp/hfp_probe_result.txt"

// 输出不缓冲：万一中途被打断，也能看到走到哪一步了
setvbuf(stdout, nil, _IONBF, 0)

var logBuffer = ""
func emit(_ items: Any...) {
    let line = items.map { String(describing: $0) }.joined(separator: " ")
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let out = "[\(stamp)] \(line)"
    print(out)
    logBuffer += out + "\n"
    try? logBuffer.write(toFile: LOG_PATH, atomically: true, encoding: .utf8)
}

/// 边跑主循环边等条件成立，好让蓝牙回调有机会进来
@discardableResult
func waitUntil(_ seconds: Double, _ label: String, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if cond() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    let ok = cond()
    if !ok { emit("  · 等「\(label)」超时（\(Int(seconds)) 秒）") }
    return ok
}

func hold(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - 系统音频设备

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let err = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    if err != noErr { return "设备 \(id)" }
    return name as String
}

func deviceTransport(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    var kind: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &kind) == noErr else { return "未知" }
    switch kind {
    case kAudioDeviceTransportTypeBluetooth:    return "蓝牙"
    case kAudioDeviceTransportTypeBluetoothLE:  return "蓝牙低功耗"
    case kAudioDeviceTransportTypeBuiltIn:      return "内置"
    case kAudioDeviceTransportTypeUSB:          return "USB"
    case kAudioDeviceTransportTypeVirtual:      return "虚拟"
    case kAudioDeviceTransportTypeAggregate:    return "聚合"
    case kAudioDeviceTransportTypeAirPlay:      return "AirPlay"
    case kAudioDeviceTransportTypeHDMI:         return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort:  return "DisplayPort"
    default:                                    return "其它"
    }
}

func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    var total = 0
    for buf in list { total += Int(buf.mNumberChannels) }
    return total
}

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
        return []
    }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
        return []
    }
    return ids
}

func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

/// 把设备清单打到标准输出。只由子进程调用。
func dumpAudioDevices() {
    let outID = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    let inID = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    print("默认输出：\(deviceName(outID))（\(deviceTransport(outID))）")
    print("默认输入：\(deviceName(inID))（\(deviceTransport(inID))）")
    let ids = allDeviceIDs()
    var lines: [String] = []
    for id in ids {
        let ins = channelCount(id, scope: kAudioObjectPropertyScopeInput)
        let outs = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        guard ins > 0 || outs > 0 else { continue }
        lines.append("· \(deviceName(id))〔\(deviceTransport(id))〕输入 \(ins) 路 / 输出 \(outs) 路")
    }
    print("设备共 \(ids.count) 个，其中有声道的 \(lines.count) 个：")
    for l in lines { print(l) }
}

/// 打一份音频设备快照。通话前后各打一份，差异就是答案。
///
/// 读设备这一步放在子进程里跑：CoreAudio 在受限环境下会直接把进程掐掉，
/// 隔一层子进程，读设备挂了不会带走通话主线。
func audioSnapshot(_ tag: String) {
    emit("── 音频设备快照 · \(tag) ──")
    let exe = CommandLine.arguments[0]
    guard exe.hasPrefix("/") else {
        emit("  （拿不到自身路径，跳过）")
        return
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = ["--audio-dump"]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        emit("  （起子进程失败：\(error.localizedDescription)）")
        return
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    let lines = text.split(separator: "\n").filter { !$0.isEmpty }
    if lines.isEmpty {
        emit("  （没读到设备清单，读设备的子进程退出码 \(proc.terminationStatus)）")
        return
    }
    for l in lines { emit("  " + l) }
}

// MARK: - 免提端

final class Probe: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    var hf: IOBluetoothHandsFreeDevice!
    var slcUp = false
    var gotIncoming = false
    var callActive = false
    var scoOpen = false

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        let code = status?.intValue ?? -1
        if code == 0 {
            slcUp = true
            emit("✓ 信令通道已建立（服务级连接）")
        } else {
            emit("✗ 信令通道建立失败，返回码 \(code)")
        }
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        slcUp = false
        emit("· 信令通道已断开")
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        let code = status?.intValue ?? -1
        if code == 0 {
            scoOpen = true
            emit("✓ 音频通道已建立（SCO）")
            audioSnapshot("SCO 刚建立")
        } else {
            emit("✗ 音频通道建立失败，返回码 \(code)")
        }
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        scoOpen = false
        emit("· 音频通道已关闭")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        gotIncoming = true
        emit("★ 来电：\(number ?? "（对方没给号码）")")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt attempt: NSNumber!) {
        emit("  响铃第 \(attempt?.intValue ?? 0) 次")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive active: NSNumber!) {
        callActive = (active?.intValue ?? 0) == 1
        emit("  通话指示器：\(callActive ? "通话中" : "无通话")")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode mode: NSNumber!) {
        let text: String
        switch mode?.intValue ?? 0 {
        case 1:  text = "来电正在接入"
        case 2:  text = "去电正在拨出"
        case 3:  text = "对方正在振铃"
        default: text = "没有通话在建立中"
        }
        emit("  通话建立状态：\(text)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable available: NSNumber!) {
        let on = (available?.intValue ?? 0) == 1
        emit("  网络服务：\(on ? "有" : "无")")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, signalStrength strength: NSNumber!) {
        emit("  信号格数：\(strength?.intValue ?? -1) / 5")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, batteryCharge charge: NSNumber!) {
        emit("  手机电量格数：\(charge?.intValue ?? -1) / 5")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, subscriberNumber number: String!) {
        emit("  手机本机号：\(number ?? "（没给）")")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall call: [AnyHashable: Any]!) {
        emit("  当前通话条目：\(call ?? [:])")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode code: String!) {
        emit("  （手机回了一条本库没处理的结果码：\(code ?? "")）")
    }
}

// MARK: - 主流程

// 子进程模式：只把设备清单打出来，然后就退出
if CommandLine.arguments.contains("--audio-dump") {
    dumpAudioDevices()
    exit(0)
}

emit("=== HFP 通话探针 ===")

// 只看音频设备、不碰蓝牙。用来单独确认设备枚举这一段本身是好的。
if CommandLine.arguments.contains("--audio-only") {
    audioSnapshot("仅看设备")
    exit(0)
}

audioSnapshot("开始前")

guard let dev = IOBluetoothDevice(addressString: PHONE_ADDR) else {
    emit("✗ 设备对象构造失败：\(PHONE_ADDR)")
    exit(1)
}
emit("目标设备：\(dev.name ?? "（没名字）")  \(dev.addressString ?? PHONE_ADDR)")
emit("手机侧 HFP 音频网关服务：\(dev.isHandsFreeAudioGateway ? "有" : "没有")")
emit("手机侧 HFP 免提端服务：\(dev.isHandsFreeDevice ? "有" : "没有")")

let probe = Probe()
probe.hf = IOBluetoothHandsFreeDevice(device: dev, delegate: probe)
guard probe.hf != nil else {
    emit("✗ 免提端对象构造失败")
    exit(1)
}

emit("")
emit("→ 建立信令通道…")
probe.hf.connect()

guard waitUntil(30, "信令通道建立", { probe.slcUp }) else {
    emit("✗ 信令通道没建起来，后面的步骤做不了")
    emit("  可能原因：手机没把 Mac 认作免提设备，或手机侧的通话音频没放开")
    exit(1)
}

let devFeatures = probe.hf.deviceSupportedFeatures
let ourFeatures = probe.hf.supportedFeatures
emit("  手机侧特性位：0x\(String(devFeatures, radix: 16))")
emit("  本机侧特性位：0x\(String(ourFeatures, radix: 16))")
emit("  是否支持短信：\(probe.hf.isSMSEnabled ? "是" : "否")")
for name in ["service", "call", "callsetup", "callheld", "signal", "roam", "battchg"] {
    emit("  指示器 \(name) = \(probe.hf.indicator(name))")
}
probe.hf.subscriberNumber()

emit("")
emit("────────────────────────────────────────")
emit("  现在请用另一部手机拨打这台手机。")
emit("  探针会等 180 秒，来电时自动接听。")
emit("────────────────────────────────────────")
emit("")

guard waitUntil(180, "来电", { probe.gotIncoming }) else {
    emit("✗ 等来电超时。没收到来电事件，HFP 的来电提醒这条路没通。")
    probe.hf.disconnect()
    exit(2)
}

hold(2.0)
emit("→ 调用 acceptCall() 接听")
probe.hf.acceptCall()

waitUntil(20, "通话接通", { probe.callActive })
hold(2.0)

emit("→ 调用 connectSCO() 建立音频通道")
probe.hf.connectSCO()
let scoOK = waitUntil(20, "音频通道建立", { probe.scoOpen })
emit("  音频通道状态：\(scoOK ? "已建立" : "未建立")，isSCOConnected = \(probe.hf.isSCOConnected())")

hold(1.0)
emit("→ 调用 transferAudioToComputer()，把通话音频转到电脑")
probe.hf.transferAudioToComputer()
hold(3.0)

audioSnapshot("通话中")

emit("")
emit("────────────────────────────────────────")
emit("  请做两件事，然后回到这里：")
emit("    1. 对着耳机麦克风说话，问对方能不能听到你")
emit("    2. 听耳机里有没有对方的声音")
emit("  探针保持 90 秒，之后自动挂断。")
emit("────────────────────────────────────────")
emit("")

hold(90.0)

emit("→ 调用 endCall() 挂断")
probe.hf.endCall()
hold(3.0)

audioSnapshot("挂断后")

emit("→ 断开信令通道")
probe.hf.disconnect()
hold(2.0)

emit("")
emit("=== 探针结束 ===")
exit(0)
