import AppKit
import SwiftUI

@main
struct CaptureLabApp: App {
    @NSApplicationDelegateAdaptor(CaptureLabAppDelegate.self) private var appDelegate
    @StateObject private var model: CaptureLabViewModel
    @StateObject private var shortcutStore = CaptureShortcutStore()
    @StateObject private var globalHotKeyController = GlobalHotKeyController()
    @StateObject private var settings: CaptureSettingsSession
    @StateObject private var statusBar = CaptureStatusBarController()
    @State private var configured = false
    @Environment(\.openWindow) private var openWindow

    init() {
        let store = CloudflareR2SettingsStore()
        let model = CaptureLabViewModel(r2SettingsStore: store)
        let session = CaptureSettingsSession(store: store, retention: model.historyStore.retention)
        _model = StateObject(wrappedValue: model)
        _settings = StateObject(wrappedValue: session)
        CaptureLabAppDelegate.documentModel = model
        CaptureLabAppDelegate.settingsSession = session
    }

    var body: some Scene {
        let _ = appDelegate.bootstrap = configureApplication
        Window(L10n.appName, id: "main") {
            CaptureLabRootView(model: model, shortcutStore: shortcutStore, showHistory: showHistory)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear(perform: configureApplication)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 680)
        .commands {
            CaptureLabCommands(
                model: model, showMainWindow: showMainWindow, showHistory: showHistory,
                showWorkflowSettings: { showSettings(nil) },
                showAboutSettings: { showSettings(.about) }
            )
        }

        Window(L10n.historyBrowserTitle, id: "capture-history") {
            CaptureHistoryView(model: model, showEditor: showMainWindow).frame(minWidth: 600, minHeight: 400)
        }.defaultSize(width: 780, height: 580)

        Window(L10n.text(en: "CaptureLab Settings", zh: "CaptureLab 设置"), id: "settings") {
            CaptureSettingsView(session: settings, model: model, shortcuts: shortcutStore,
                                hotKeys: globalHotKeyController, registerShortcut: registerGlobalHotKey)
        }.defaultSize(width: 900, height: 640)

        Window(L10n.captureLauncher, id: "capture-launcher") {
            CaptureLauncherView(model: model, shortcuts: shortcutStore)
        }.windowResizability(.contentSize)

        Window(L10n.text(en: "Recognition Results", zh: "识别结果"), id: "recognition-results") {
            DirectRecognitionView(controller: model.directRecognition) { kind in
                model.performCaptureAction(kind == .text ? .text : .qrCode)
            }
        }.defaultSize(width: 560, height: 400)
    }

    private func showMainWindow() {
        CaptureLabAppDelegate.allowNextMainWindowPresentation()
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
    private func configureApplication() {
        guard !configured else { return }
        configured = true
        model.presentEditor = showMainWindow
        model.presentRecognition = { showUtilityWindow("recognition-results") }
        model.presentCaptureLauncher = { showUtilityWindow("capture-launcher") }
        model.presentUploadSettings = { showSettings(.upload) }
        for action in CaptureAction.allCases {
            _ = registerGlobalHotKey(action, shortcutStore.shortcut(for: action))
        }
        statusBar.install(model: model, shortcuts: shortcutStore, hotKeys: globalHotKeyController,
                          showEditor: showMainWindow, showHistory: showHistory,
                          showSettings: { category, shortcut in showSettings(category, shortcut: shortcut) })
        appDelegate.openPendingProjects()
    }
    private func showUtilityWindow(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func showHistory() {
        model.refreshHistory()
        showUtilityWindow("capture-history")
    }
    private func showSettings(_ category: CaptureSettingsSection?, shortcut: CaptureAction? = nil) {
        settings.navigate(to: category, shortcut: shortcut)
        showUtilityWindow("settings")
    }
    private func registerGlobalHotKey(_ action: CaptureAction, _ shortcut: CaptureKeyboardShortcut?) -> String? {
        let registered = globalHotKeyController.configure(action: action, shortcut: shortcut) {
            model.performCaptureAction(action)
        }
        return registered ? nil : globalHotKeyController.actionErrors[action]
            ?? L10n.globalShortcutRegistrationFailed(shortcut?.displayTitle ?? action.title)
    }
}

@MainActor
final class CaptureLabAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("CaptureLab.main-window")
    private static var shouldSuppressNextMainWindow = true
    static weak var documentModel: CaptureLabViewModel?
    static weak var settingsSession: CaptureSettingsSession?
    var bootstrap: (() -> Void)?
    private var pendingProjectURLs: [URL] = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.settingsSession?.prepareForClose() != false else { return .terminateCancel }
        return Self.documentModel?.prepareForTermination() == false ? .terminateCancel : .terminateNow
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
        bootstrap?()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenCaptureLifecycle.shared.shutdown()
    }
}
