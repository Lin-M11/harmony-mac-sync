import SwiftUI
import AppKit

/// 菜单栏应用。
///
/// 不占 Dock：Info.plist 里 `LSUIElement` 为真，启动时再把激活策略设成 accessory，
/// 两道都做，免得某一种启动路径下漏出 Dock 图标。
@main
struct HarmonySyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(nsImage: model.menuBarImage)
                .accessibilityLabel("鸿蒙短信同步")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 通知身份：先问一次授权，之后新短信就能以 App 的名义弹出来
        Notifier.shared.prepare()
        _ = AppModel.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
