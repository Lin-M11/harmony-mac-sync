import SwiftUI
import AppKit

/// 菜单栏面板。三段：连接、监听、最近收到；底部一条主操作。
///
/// 宽度固定 300。分区之间用 1px 分隔线，不用卡片——面板本身就是一张面。
struct PanelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.picking {
                DevicePickerView()
            } else {
                head
                HairLine()
                monitorSection
                HairLine()
                recentSection
                HairLine()
                foot
            }
        }
        .frame(width: 300)
        .background(Color.hsSurface)
        .onAppear { model.scanPairedDevices() }
    }

    // MARK: 头部

    private var head: some View {
        HStack(alignment: .center, spacing: HS.s3) {
            LinkMark(linked: model.link == .connected,
                     color: model.link == .connected ? .hsAccent : .hsInk3,
                     width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.titleText)
                    .font(.hsBodyStrong)
                    .foregroundStyle(Color.hsInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.statusNote.isEmpty {
                    Text(model.statusNote)
                        .font(.hsCaption)
                        .foregroundStyle(Color.hsInk3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: HS.s2)

            StateChip(kind: model.stateChip, text: model.stateLabel)
        }
        .padding(.horizontal, HS.s4)
        .padding(.vertical, HS.s3)
    }

    // MARK: 监听开关

    private var monitorSection: some View {
        VStack(spacing: 0) {
            SettingRow(title: "短信监听", hint: "收到新短信时同步到 Mac") {
                HSSwitch(isOn: Binding(get: { model.smsMonitoring },
                                       set: { model.setSmsMonitoring($0) }))
            }
            SettingRow(title: "通话监听", hint: "手机来电时在 Mac 上提示") {
                HSSwitch(isOn: Binding(get: { model.callMonitoring },
                                       set: { model.setCallMonitoring($0) }))
            }
            SettingRow(title: "开机自启", hint: "登录后在菜单栏待命") {
                HSSwitch(isOn: Binding(get: { model.launchAtLogin },
                                       set: { model.setLaunchAtLogin($0) }))
            }
            SettingRow(title: "手机", hint: model.deviceName.isEmpty ? "尚未选择" : model.deviceName) {
                PanelButton(title: "更换…", kind: .plain, fillWidth: false) {
                    model.scanPairedDevices()
                    model.picking = true
                }
            }
        }
    }

    // MARK: 最近收到

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HS.s2) {
                Text("最近收到")
                    .font(.hsBodyStrong)
                    .foregroundStyle(Color.hsInk)
                Spacer(minLength: HS.s2)
                Text("共 \(model.totalCount) 条")
                    .font(.hsCaption)
                    .monospacedDigit()
                    .foregroundStyle(Color.hsInk3)
            }
            .padding(.horizontal, HS.s4)
            .padding(.top, HS.s3)
            .padding(.bottom, HS.s2)

            if model.recent.isEmpty {
                Text("还没有收到短信")
                    .font(.hsCaption)
                    .foregroundStyle(Color.hsInk3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HS.s4)
                    .padding(.bottom, HS.s3)
            } else {
                ForEach(model.recent) { m in
                    recentRow(m)
                }
            }
        }
    }

    private func recentRow(_ m: StoredMessage) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: HS.s2) {
                Text(m.displayName)
                    .font(.hsCaption)
                    .foregroundStyle(Color.hsInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: HS.s2)
                Text(PanelView.clock(m.sentAt))
                    .font(.hsCaption)
                    .monospacedDigit()
                    .foregroundStyle(Color.hsInk3)
            }
            Text(m.body.replacingOccurrences(of: "\n", with: " "))
                .font(.hsCaption)
                .foregroundStyle(Color.hsInk2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, HS.s4)
        .padding(.vertical, HS.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 底部

    private var foot: some View {
        HStack(spacing: HS.s2) {
            PanelButton(title: "打开消息记录", kind: .primary) {
                dismissMenuBarPanel()
                MessageWindowController.shared.show()
            }
            PanelButton(title: model.smsMonitoring ? "断开" : "连接手机…",
                        kind: .plain, fillWidth: false) {
                if model.smsMonitoring {
                    model.disconnect()
                } else {
                    model.scanPairedDevices()
                    model.picking = true
                }
            }
        }
        .padding(.horizontal, HS.s4)
        .padding(.vertical, HS.s3)
    }

    /// 面板里只报时刻：日期由「最近收到」的上下文兜住
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 选手机

/// 首次连接，或用户主动更换手机时，面板切到这一页。
struct DevicePickerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HS.s2) {
                Text("选择手机")
                    .font(.hsBodyStrong)
                    .foregroundStyle(Color.hsInk)
                Spacer(minLength: HS.s2)
                PanelButton(title: "重新扫描", kind: .plain, fillWidth: false) {
                    model.scanPairedDevices()
                }
                if !model.needsSetup {
                    PanelButton(title: "返回", kind: .plain, fillWidth: false) {
                        model.picking = false
                    }
                }
            }
            .padding(.horizontal, HS.s4)
            .padding(.vertical, HS.s3)

            HairLine()

            if model.pairedDevices.isEmpty {
                VStack(alignment: .leading, spacing: HS.s2) {
                    Text("没有找到已配对的设备")
                        .font(.hsBodyStrong)
                        .foregroundStyle(Color.hsInk)
                    Text("先在「系统设置 → 蓝牙」里把手机与这台 Mac 配对，再回来点「重新扫描」。")
                        .font(.hsCaption)
                        .foregroundStyle(Color.hsInk3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HS.s4)
                .padding(.vertical, HS.s3)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.pairedDevices) { d in
                            deviceRow(d)
                            if d.id != model.pairedDevices.last?.id { HairLine() }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func deviceRow(_ d: AppModel.PairedDevice) -> some View {
        Button {
            model.chooseDevice(d)
        } label: {
            HStack(spacing: HS.s3) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name)
                        .font(.hsBodyStrong)
                        .foregroundStyle(Color.hsInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(d.address)
                        .font(.hsMono)
                        .foregroundStyle(Color.hsInk3)
                        .lineLimit(1)
                }
                Spacer(minLength: HS.s2)
                if d.address == model.chosenAddress {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.hsAccent)
                }
            }
            .padding(.horizontal, HS.s4)
            .padding(.vertical, HS.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(RowSurface(hovered: hovered == d.id, selected: d.address == model.chosenAddress))
        .onHover { hovered = $0 ? d.id : (hovered == d.id ? nil : hovered) }
    }
}
