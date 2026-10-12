import Foundation
import SwiftUI
import AppKit
import IOBluetooth
import ServiceManagement

/// 界面状态与引擎之间的那一层。
///
/// 引擎（Sync / MnsServer）的委托回调都落在主 RunLoop 上，这里的方法也都在主线程调，
/// 所以直接改 @Published 即可，不额外加隔离标注。
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum LinkState { case off, connecting, connected }

    struct PairedDevice: Identifiable, Hashable {
        let address: String
        let name: String
        var id: String { address }
    }

    // MARK: 界面状态

    @Published private(set) var link: LinkState = .off
    @Published private(set) var recent: [StoredMessage] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var deviceName = ""
    @Published private(set) var smsMonitoring = false
    @Published private(set) var callMonitoring = false
    @Published private(set) var launchAtLogin = false
    @Published var statusNote = ""
    /// 面板切成设备列表：首次连接，或用户主动点「连接手机…」
    @Published var picking = false

    /// 还没选过手机
    var needsSetup: Bool { deviceAddress.isEmpty }

    /// 当前选中的手机地址，供设备列表标出选中项
    var chosenAddress: String { deviceAddress }

    var statusText: String {
        if needsSetup { return "尚未连接手机" }
        switch link {
        case .connected: return "链路已建立"
        case .connecting: return "正在建立链路…"
        case .off: return "链路未建立"
        }
    }

    /// 面板头部的标题：选了手机就报手机名
    var titleText: String {
        if needsSetup { return "未连接手机" }
        return deviceName.isEmpty ? "鸿蒙短信同步" : deviceName
    }

    /// 状态指示的短标签
    var stateLabel: String {
        if needsSetup { return "未连接" }
        switch link {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .off: return "未连接"
        }
    }

    var stateChip: StateChip.Kind {
        if needsSetup { return .off }
        switch link {
        case .connected: return .on
        case .connecting: return .wait
        case .off: return .off
        }
    }

    var menuBarImage: NSImage {
        let name = link == .connected ? "MenuBarIconTemplate" : "MenuBarIconOffTemplate"
        if let img = NSImage(named: name) {
            img.isTemplate = true
            return img
        }
        return NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                       accessibilityDescription: "鸿蒙短信同步") ?? NSImage()
    }

    // MARK: 私有

    let store: Store
    private var sync: Sync?
    private var mns: MnsServer?
    private var deviceAddress = ""
    private var channelID: BluetoothRFCOMMChannelID = CHANNEL_DEFAULT

    private enum Key {
        static let sms = "smsMonitoring"
        static let call = "callMonitoring"
        static let address = "deviceAddress"
        static let channel = "deviceChannel"
    }

    private init() {
        guard let s = Store(path: DB_PATH) else {
            fatalError("打不开数据库：\(DB_PATH)")
        }
        store = s

        deviceAddress = UserDefaults.standard.string(forKey: Key.address) ?? ""
        let saved = UserDefaults.standard.integer(forKey: Key.channel)
        if saved > 0 { channelID = BluetoothRFCOMMChannelID(saved) }
        callMonitoring = UserDefaults.standard.bool(forKey: Key.call)
        smsMonitoring = UserDefaults.standard.bool(forKey: Key.sms)
        refreshLaunchAtLogin()

        if !deviceAddress.isEmpty, let d = IOBluetoothDevice(addressString: deviceAddress) {
            deviceName = d.name ?? deviceAddress
        }
        refresh()

        // 选过手机、开关也开着，开机就把链路接上
        if !needsSetup && smsMonitoring { start() }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: 开关

    func setSmsMonitoring(_ on: Bool) {
        smsMonitoring = on
        UserDefaults.standard.set(on, forKey: Key.sms)
        if on { start() } else { stop() }
    }

    func setCallMonitoring(_ on: Bool) {
        callMonitoring = on
        UserDefaults.standard.set(on, forKey: Key.call)
        if on && link == .off && !needsSetup { start() }
        if !on { statusNote = "" }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            statusNote = "开机自启没设上：\(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: 连接

    func scanPairedDevices() {
        pairedDevices = Self.pairedDevices()
    }

    func chooseDevice(_ d: PairedDevice) {
        deviceAddress = d.address
        deviceName = d.name
        UserDefaults.standard.set(d.address, forKey: Key.address)
        if let dev = IOBluetoothDevice(addressString: d.address) {
            channelID = Self.mapChannel(for: dev)
        }
        UserDefaults.standard.set(Int(channelID), forKey: Key.channel)
        picking = false
        statusNote = ""
        smsMonitoring = true
        UserDefaults.standard.set(true, forKey: Key.sms)
        start()
    }

    /// 断开：关掉通道，开关也跟着落下来（这个开关就是「要不要连着」）。
    func disconnect() {
        smsMonitoring = false
        UserDefaults.standard.set(false, forKey: Key.sms)
        stop()
    }

    private func start() {
        guard !deviceAddress.isEmpty else { picking = true; return }
        guard sync == nil else { return }
        guard let device = IOBluetoothDevice(addressString: deviceAddress) else {
            link = .off
            statusNote = "找不到设备 \(deviceAddress)"
            smsMonitoring = false
            UserDefaults.standard.set(false, forKey: Key.sms)
            return
        }

        link = .connecting
        statusNote = ""

        let s = Sync(store: store, device: device, channelID: channelID, once: false)
        s.onLinkChange = { [weak self] up in
            self?.onMain {
                guard let self else { return }
                self.link = up ? .connected : .connecting
                self.statusNote = up ? "" : "链路断开，正在重连…"
                self.refresh()
            }
        }
        s.onNewMessages = { [weak self] _ in self?.onMain { self?.refresh() } }
        s.onPoll = { [weak self] in
            self?.onMain {
                self?.lastSyncAt = Date()
                self?.refresh()
            }
        }
        sync = s
        s.start()

        // 事件订阅是秒级延迟那条路：手机推来事件就立刻拉一次
        if mnsEnabled {
            let m = MnsServer()
            m.ignoreChannelID = channelID
            m.start { [weak self] detail in
                self?.onMain { self?.statusNote = detail }
                s.pollNow(detail)
            }
            mns = m
        }
    }

    private func stop() {
        sync?.stop()
        sync = nil
        mns?.stop()
        mns = nil
        link = .off
        statusNote = ""
        refresh()
    }

    // MARK: 读库

    func refresh() {
        recent = store.recentMessages(limit: 2)
        totalCount = store.count("message")
    }

    // MARK: 蓝牙

    static func pairedDevices() -> [PairedDevice] {
        let list = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return list.compactMap { d -> PairedDevice? in
            guard let a = d.addressString, !a.isEmpty else { return nil }
            let n = (d.name?.isEmpty == false) ? d.name! : a
            return PairedDevice(address: a, name: n)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// MAP MAS 的 RFCOMM 通道号从 SDP 里查；查不到退回默认值。
    static func mapChannel(for device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID {
        let uuid = IOBluetoothSDPUUID(uuid16: 0x1132)
        if let rec = device.getServiceRecord(for: uuid) {
            var cid: BluetoothRFCOMMChannelID = 0
            if rec.getRFCOMMChannelID(&cid) == kIOReturnSuccess, cid != 0 { return cid }
        }
        return CHANNEL_DEFAULT
    }
}
