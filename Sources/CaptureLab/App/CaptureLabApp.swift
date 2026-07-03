import AppKit
import SwiftUI

@main
struct CaptureLabApp: App {
    @NSApplicationDelegateAdaptor(CaptureLabAppDelegate.self) private var appDelegate
    @StateObject private var model: CaptureLabViewModel
    @StateObject private var shortcutStore = CaptureShortcutStore()
    @StateObject private var r2SettingsStore: CloudflareR2SettingsStore
    @Environment(\.openWindow) private var openWindow

    init() {
        let r2SettingsStore = CloudflareR2SettingsStore()
        _r2SettingsStore = StateObject(wrappedValue: r2SettingsStore)
        _model = StateObject(wrappedValue: CaptureLabViewModel(r2SettingsStore: r2SettingsStore))
    }

    var body: some Scene {
        Window(L10n.appName, id: "main") {
            CaptureLabRootView(
                model: model,
                shortcutStore: shortcutStore
            )
                .frame(minWidth: 1_080, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_080, height: 620)

        Window(L10n.shortcutSettingsTitle, id: "shortcut-settings") {
            ShortcutSettingsView(shortcutStore: shortcutStore)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 220)

        Window(L10n.cloudflareR2SettingsTitle, id: "cloudflare-r2-settings") {
            CloudflareR2SettingsView(store: r2SettingsStore)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 440)

        MenuBarExtra(L10n.appName, systemImage: "viewfinder") {
            CaptureLabMenuBarView(
                model: model,
                shortcutStore: shortcutStore,
                showMainWindow: showMainWindow,
                showShortcutSettings: showShortcutSettings,
                showR2Settings: showR2Settings
            )
        }
        .commands {
            CaptureLabCommands(
                model: model,
                shortcutStore: shortcutStore,
                showMainWindow: showMainWindow,
                showR2Settings: showR2Settings
            )
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showShortcutSettings() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "shortcut-settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showR2Settings() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "cloudflare-r2-settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class CaptureLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            self.closeAutomaticallyOpenedMainWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.closeAutomaticallyOpenedMainWindow()
        }
    }

    private func closeAutomaticallyOpenedMainWindow() {
        for window in NSApp.windows where window.title == L10n.appName && window.isVisible {
            window.close()
        }
    }
}
