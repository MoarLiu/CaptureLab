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
        let model = CaptureLabViewModel(r2SettingsStore: r2SettingsStore)
        _model = StateObject(wrappedValue: model)
        CaptureLabAppDelegate.documentModel = model
    }

    var body: some Scene {
        Window(L10n.appName, id: "main") {
            CaptureLabRootView(
                model: model,
                shortcutStore: shortcutStore,
                showHistory: showHistory
            )
                .frame(minWidth: 1_080, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_080, height: 620)

        Window(L10n.historyBrowserTitle, id: "capture-history") {
            CaptureHistoryView(model: model, showEditor: showMainWindow)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 780, height: 580)

        Window(L10n.workflowSettings, id: "workflow-settings") {
            CaptureWorkflowSettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 620)

        Window(L10n.shortcutSettingsTitle, id: "shortcut-settings") {
            ShortcutSettingsView(
                shortcutStore: shortcutStore,
                controller: globalHotKeyController,
                onSave: registerGlobalHotKey
            )
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 220)

        Window(L10n.captureLauncher, id: "capture-launcher") {
            CaptureLauncherView(model: model)
        }.windowResizability(.contentSize)

        Window(L10n.recognitionLanguages, id: "recognition-settings") {
            RecognitionSettingsView()
        }.windowResizability(.contentSize)

        Window(L10n.text(en: "Recognition Results", zh: "识别结果"), id: "recognition-results") {
            DirectRecognitionView(controller: model.directRecognition)
        }.defaultSize(width: 560, height: 400)

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
                showHistory: showHistory,
                showShortcutSettings: showShortcutSettings,
                showR2Settings: showR2Settings,
                showWorkflowSettings: showWorkflowSettings
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
                showHistory: showHistory,
                showR2Settings: showR2Settings,
                showWorkflowSettings: showWorkflowSettings
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
        model.presentEditor = showMainWindow
        appDelegate.openPendingProjects()
        model.presentRecognition = { showUtilityWindow("recognition-results") }
        model.presentCaptureLauncher = { showUtilityWindow("capture-launcher") }
        for action in CaptureAction.allCases {
            _ = registerGlobalHotKey(action, shortcutStore.shortcut(for: action))
        }
    }

    private func showUtilityWindow(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showHistory() {
        model.refreshHistory()
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "capture-history")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func registerGlobalHotKey(_ action: CaptureAction, _ shortcut: CaptureKeyboardShortcut?) -> String? {
        let didRegister = globalHotKeyController.configure(action: action, shortcut: shortcut) {
            model.performCaptureAction(action)
        }
        return didRegister ? nil : globalHotKeyController.actionErrors[action]
            ?? L10n.globalShortcutRegistrationFailed(shortcut?.displayTitle ?? action.title)
    }

    private func showWorkflowSettings() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "workflow-settings")
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

@MainActor
final class CaptureLabAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("CaptureLab.main-window")
    private static var shouldSuppressNextMainWindow = true
    static weak var documentModel: CaptureLabViewModel?
    private var pendingProjectURLs: [URL] = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.documentModel?.preserveDocumentBeforeReplacement() == false ? .terminateCancel : .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingProjectURLs.append(contentsOf: urls.filter { $0.pathExtension.lowercased() == "capturelab" })
        openPendingProjects()
    }

    func openPendingProjects() {
        guard let model = Self.documentModel, let present = model.presentEditor else { return }
        let urls = pendingProjectURLs
        pendingProjectURLs = []
        for url in urls {
            if model.openProject(at: url) { present() }
        }
    }

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
