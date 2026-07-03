import AppKit
import SwiftUI

@main
struct CaptureLabApp: App {
    @NSApplicationDelegateAdaptor(CaptureLabAppDelegate.self) private var appDelegate
    @StateObject private var model = CaptureLabViewModel()
    @StateObject private var shortcutStore = CaptureShortcutStore()
    @Environment(\.openWindow) private var openWindow

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

        MenuBarExtra(L10n.appName, systemImage: "viewfinder") {
            CaptureLabMenuBarView(
                model: model,
                shortcutStore: shortcutStore,
                showMainWindow: showMainWindow,
                showShortcutSettings: showShortcutSettings
            )
        }
        .commands {
            CaptureLabCommands(
                model: model,
                shortcutStore: shortcutStore,
                showMainWindow: showMainWindow
            )
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showShortcutSettings() {
        openWindow(id: "shortcut-settings")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class CaptureLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
