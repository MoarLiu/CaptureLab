import AppKit
import Combine

/// An actual NSMenu gives icons, key equivalents and submenu arrows their
/// native columns. Carbon remains the only global shortcut registrar.
@MainActor
final class CaptureStatusBarController: NSObject, ObservableObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var model: CaptureLabViewModel?
    private var shortcuts: CaptureShortcutStore?
    private var hotKeys: GlobalHotKeyController?
    private var showEditor: () -> Void = {}
    private var showHistory: () -> Void = {}
    private var showSettings: (CaptureSettingsSection?, CaptureAction?) -> Void = { _, _ in }

    func install(model: CaptureLabViewModel, shortcuts: CaptureShortcutStore, hotKeys: GlobalHotKeyController,
                 showEditor: @escaping () -> Void, showHistory: @escaping () -> Void,
                 showSettings: @escaping (CaptureSettingsSection?, CaptureAction?) -> Void) {
        self.model = model; self.shortcuts = shortcuts; self.hotKeys = hotKeys
        self.showEditor = showEditor; self.showHistory = showHistory; self.showSettings = showSettings
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: L10n.appName)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = L10n.appName
        item.button?.setAccessibilityLabel(L10n.appName)
        let menu = NSMenu(title: L10n.appName)
        menu.autoenablesItems = false; menu.delegate = self
        item.menu = menu; statusItem = item
    }
    func menuWillOpen(_ menu: NSMenu) { populate(menu) }

    /// Also used by fixture verification without creating a system status item.
    func populate(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        guard let model else { return }
        let ready = model.canStartCapture
        menu.addItem(captureItem("region", .region, symbol: "viewfinder", action: .region))
        menu.addItem(captureItem("window", .window, symbol: "macwindow", action: .window))
        menu.addItem(captureItem("fullScreen", .fullScreen, symbol: "display", action: .fullScreen))
        let more = submenu("moreCapture", title: L10n.moreCapture, symbol: "ellipsis.circle", enabled: ready)
        more.submenu?.addItem(captureItem("lastRegion", .lastRegion, symbol: "arrow.counterclockwise", action: .lastRegion))
        more.submenu?.addItem(captureItem("frozenRegion", .frozenRegion, symbol: "snowflake"))
        more.submenu?.addItem(captureItem("delay3", .delayedRegion(seconds: 3), symbol: "timer", action: .delayedRegion))
        more.submenu?.addItem(captureItem("delay5", .delayedRegion(seconds: 5), symbol: "timer"))
        more.submenu?.addItem(.separator())
        more.submenu?.addItem(captureItem("precise", .preciseRegion, symbol: "ruler"))
        more.submenu?.addItem(item("launcher", title: L10n.captureLauncher, symbol: "square.grid.2x2", enabled: ready,
                                  shortcut: effectiveShortcut(.launcher)) { model.performCaptureAction(.launcher) })
        menu.addItem(more)
        let recognition = submenu("recognition", title: L10n.recognitionMenu, symbol: "text.viewfinder", enabled: ready)
        recognition.submenu?.addItem(item("text", title: L10n.directText, symbol: "text.viewfinder", enabled: ready,
                                         shortcut: effectiveShortcut(.text)) { model.performCaptureAction(.text) })
        recognition.submenu?.addItem(item("qrCode", title: L10n.directQRCode, symbol: "qrcode", enabled: ready,
                                         shortcut: effectiveShortcut(.qrCode)) { model.performCaptureAction(.qrCode) })
        menu.addItem(recognition)
        if let errors = hotKeys?.actionErrors, let action = CaptureAction.allCases.first(where: {
            errors[$0] != nil && hotKeys?.registeredShortcut(for: $0) == nil
        }) {
            let error = item("shortcutError", title: L10n.shortcutUnavailable, symbol: "exclamationmark.triangle", enabled: true) { [weak self] in
                self?.showSettings(.shortcuts, action)
            }
            error.toolTip = errors[action]
            menu.addItem(error)
        }
        menu.addItem(.separator())
        let open = submenu("open", title: L10n.text(en: "Open", zh: "打开"), symbol: "folder", enabled: ready)
        open.submenu?.addItem(item("openImage", title: L10n.openImage, symbol: "photo", enabled: ready) { [weak self] in self?.showEditor(); model.openImage() })
        open.submenu?.addItem(item("openProject", title: L10n.openProjectMenu, symbol: "doc", enabled: ready) { [weak self] in self?.showEditor(); model.openProject() })
        open.submenu?.addItem(item("paste", title: model.hasImage ? L10n.text(en: "Paste into Current Image", zh: "粘贴到当前图片")
                                  : L10n.text(en: "Open from Clipboard", zh: "从剪贴板打开"), symbol: "doc.on.clipboard", enabled: ready) { [weak self] in
            model.pasteImage(); if model.hasImage { self?.showEditor() }
        })
        menu.addItem(open)
        let recent = submenu("recent", title: L10n.recentCaptures, symbol: "clock.arrow.circlepath", enabled: !model.isCapturing)
        for entry in model.historyItems.prefix(5) {
            recent.submenu?.addItem(item("recent-\(entry.id)", title: entry.displayTitle, symbol: "photo", enabled: ready) { [weak self] in
                self?.showEditor(); model.openHistoryItem(entry)
            })
        }
        if model.historyItems.isEmpty {
            recent.submenu?.addItem(item("emptyHistory", title: L10n.noRecentCaptures, enabled: false) {})
        }
        recent.submenu?.addItem(.separator())
        recent.submenu?.addItem(item("history", title: L10n.showAllHistory, symbol: "square.grid.2x2", enabled: !model.isCapturing) { [weak self] in self?.showHistory() })
        menu.addItem(recent)
        menu.addItem(item("editor", title: L10n.openEditor, symbol: "square.and.pencil", enabled: !model.isCapturing) { [weak self] in self?.showEditor() })
        let overlay = model.overlayController
        let pins = CapturePinController.shared
        if !overlay.entries.isEmpty || overlay.lastClosed != nil || !pins.windows.isEmpty {
            menu.addItem(.separator())
            let management = submenu("windows", title: L10n.overlaysAndPins, symbol: "rectangle.on.rectangle", enabled: !model.isCapturing)
            if !overlay.entries.isEmpty {
                management.submenu?.addItem(item("overlayVisibility", title: overlay.isTemporarilyHidden ? L10n.overlayShow : L10n.overlayHide, enabled: !model.isCapturing) { overlay.toggleHidden() })
            }
            if overlay.lastClosed != nil {
                management.submenu?.addItem(item("overlayRestore", title: L10n.overlayRestore, enabled: !model.isCapturing) { overlay.restoreLast() })
            }
            if !pins.windows.isEmpty {
                if !(management.submenu?.items.isEmpty ?? true) { management.submenu?.addItem(.separator()) }
                management.submenu?.addItem(item("unlockPins", title: L10n.pinUnlockAll, enabled: !model.isCapturing) { pins.unlockAll() })
                management.submenu?.addItem(item("closePins", title: L10n.pinCloseAll, enabled: !model.isCapturing) { pins.closeAll() })
            }
            menu.addItem(management)
        }
        menu.addItem(.separator())
        let settings = item("settings", title: L10n.settingsTitle, symbol: "gearshape", enabled: true) { [weak self] in self?.showSettings(nil, nil) }
        settings.keyEquivalent = ","; settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(item("about", title: L10n.text(en: "About CaptureLab…", zh: "关于 CaptureLab…"), symbol: "info.circle", enabled: true) { [weak self] in self?.showSettings(.about, nil) })
        menu.addItem(item("quit", title: L10n.quitCaptureLab, enabled: true) { NSApp.terminate(nil) })
    }

    private func effectiveShortcut(_ action: CaptureAction) -> CaptureKeyboardShortcut? {
        return hotKeys?.registeredShortcut(for: action)
    }
    private func captureItem(_ id: String, _ mode: CaptureMode, symbol: String, action: CaptureAction? = nil) -> NSMenuItem {
        item(id, title: mode.title, symbol: symbol, enabled: model?.canStartCapture ?? false,
             shortcut: action.flatMap(effectiveShortcut)) { [weak self] in self?.model?.capture(mode) }
    }
    private func submenu(_ id: String, title: String, symbol: String, enabled: Bool) -> NSMenuItem {
        let result = item(id, title: title, symbol: symbol, enabled: enabled) {}
        result.submenu = NSMenu(title: title); result.submenu?.autoenablesItems = false
        return result
    }
    private func item(_ id: String, title: String, symbol: String? = nil, enabled: Bool,
                      shortcut: CaptureKeyboardShortcut? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: shortcut?.key ?? "")
        result.identifier = .init(id); result.target = self; result.isEnabled = enabled
        result.representedObject = MenuAction(action)
        if let symbol {
            result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            result.image?.size = NSSize(width: 16, height: 16)
            if #available(macOS 27.0, *) { result.preferredImageVisibility = .visible }
        }
        if let shortcut {
            var flags: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { flags.insert(.command) }
            if shortcut.modifiers.contains(.control) { flags.insert(.control) }
            if shortcut.modifiers.contains(.option) { flags.insert(.option) }
            if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
            result.keyEquivalentModifierMask = flags
        }
        return result
    }
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard sender.isEnabled else { return }
        (sender.representedObject as? MenuAction)?.perform()
    }
    private final class MenuAction: NSObject {
        let perform: () -> Void
        init(_ perform: @escaping () -> Void) { self.perform = perform }
    }
}
