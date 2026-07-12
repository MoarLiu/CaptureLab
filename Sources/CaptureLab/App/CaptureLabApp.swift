import AppKit
import SwiftUI

@main
struct CaptureLabApp: App {
    @NSApplicationDelegateAdaptor(CaptureLabAppDelegate.self) private var appDelegate
    @StateObject private var model: CaptureLabViewModel
    @StateObject private var shortcutStore = CaptureShortcutStore()
    @StateObject private var r2SettingsStore: CloudflareR2SettingsStore
    @StateObject private var globalHotKeyController = GlobalHotKeyController()
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
            ShortcutSettingsView(
                shortcutStore: shortcutStore,
                onSave: registerGlobalHotKey
            )
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 220)

        Window(L10n.cloudflareR2SettingsTitle, id: "cloudflare-r2-settings") {
            CloudflareR2SettingsView(store: r2SettingsStore)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 440)

        MenuBarExtra {
            CaptureLabMenuBarView(
                model: model,
                shortcutStore: shortcutStore,
                globalHotKeyController: globalHotKeyController,
                showMainWindow: showMainWindow,
                showShortcutSettings: showShortcutSettings,
                showR2Settings: showR2Settings
            )
        } label: {
            Label(L10n.appName, systemImage: "viewfinder")
                .onAppear(perform: configureGlobalHotKey)
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
        CaptureLabAppDelegate.allowNextMainWindowPresentation()
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureGlobalHotKey() {
        _ = globalHotKeyController.configure(shortcut: shortcutStore.captureShortcut) {
            model.capture(.region, onSuccess: showMainWindow)
        }
    }

    private func registerGlobalHotKey(_ shortcut: CaptureKeyboardShortcut) -> String? {
        let didRegister = globalHotKeyController.configure(shortcut: shortcut) {
            model.capture(.region, onSuccess: showMainWindow)
        }
        return didRegister
            ? nil
            : globalHotKeyController.registrationError
                ?? L10n.globalShortcutRegistrationFailed(shortcut.displayTitle)
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

@MainActor
final class CaptureLabAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("CaptureLab.main-window")
    private static var shouldSuppressNextMainWindow = true

    static func allowNextMainWindowPresentation() {
        shouldSuppressNextMainWindow = false
    }

    static func configureMainWindow(_ window: NSWindow) {
        window.identifier = mainWindowIdentifier
        guard shouldSuppressNextMainWindow else {
            return
        }

        shouldSuppressNextMainWindow = false
        window.close()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        try? ScreenCaptureLifecycle.shared.prepareForLaunch()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenCaptureLifecycle.shared.shutdown()
    }
}
