import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var shortcutStore: CaptureShortcutStore
    @ObservedObject var controller: GlobalHotKeyController
    let onSave: (CaptureAction, CaptureKeyboardShortcut?) -> String?
    @State private var selectedAction = CaptureAction.region
    @State private var draftShortcut = CaptureKeyboardShortcut.defaultCapture
    @State private var enabled = true
    @State private var saveError: String?
    @State private var saved = false
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.shortcutSettingsTitle).font(.title2)
            Picker(L10n.text(en: "Action", zh: "操作"), selection: $selectedAction) {
                ForEach(CaptureAction.allCases) { action in
                    Text(action.title + "  " + (shortcutStore.shortcut(for: action)?.displayTitle ?? "—")).tag(action)
                }
            }
            if selectedAction != .region {
                Toggle(L10n.text(en: "Enable global shortcut", zh: "启用全局快捷键"), isOn: $enabled)
            }
            if enabled {
                ShortcutRecorderView(shortcut: $draftShortcut, cancelAction: { window?.close() }).frame(height: 48)
                Text(L10n.text(en: "Press a key with Command, Control or Option. Physical key positions are preserved, including Shift and non-US keyboards.",
                    zh: "按下包含 Command、Control 或 Option 的组合键。按实体键位保存，支持 Shift 组合和非美式键盘。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = saveError ?? controller.actionErrors[selectedAction] {
                Text(message).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if saved { Text(L10n.text(en: "Saved", zh: "已保存")).foregroundStyle(.secondary) }
                Spacer()
                Button(L10n.cancel) { window?.close() }
                Button(L10n.save, action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 500)
        .background(ShortcutSettingsWindowReader(window: $window))
        .onAppear(perform: load)
        .onChange(of: selectedAction) { _ in load() }
        .onChange(of: draftShortcut) { _ in saved = false; saveError = nil }
        .onChange(of: enabled) { _ in saved = false; saveError = nil }
        .captureLabWindowCloseShortcuts()
    }
    private func load() {
        let value = shortcutStore.shortcut(for: selectedAction)
        enabled = value != nil
        draftShortcut = value ?? .defaultCapture
        saveError = nil; saved = false
    }
    private func save() {
        let value = enabled ? draftShortcut : nil
        if let value, let conflict = shortcutStore.conflict(for: value, action: selectedAction) {
            saveError = L10n.text(en: "Already assigned to \(conflict.title).", zh: "已用于“\(conflict.title)”。")
            return
        }
        saved = shortcutStore.save(value, for: selectedAction) {
            saveError = onSave(selectedAction, value)
            return saveError == nil
        }
        if !saved && saveError == nil { saveError = L10n.globalShortcutUnsupported(draftShortcut.displayTitle) }
    }
}

private struct ShortcutSettingsWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            window = nsView.window
        }
    }
}

private struct ShortcutRecorderView: View {
    @Binding var shortcut: CaptureKeyboardShortcut
    let cancelAction: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)

            HStack {
                Text(shortcut.displayTitle)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer()
                Text(L10n.recordingShortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
        }
        .background(
            ShortcutRecorderBridge(
                shortcut: $shortcut,
                cancelAction: cancelAction
            )
        )
    }
}

private struct ShortcutRecorderBridge: NSViewRepresentable {
    @Binding var shortcut: CaptureKeyboardShortcut
    let cancelAction: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        view.onCancel = cancelAction
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        nsView.onCancel = cancelAction
    }

    final class RecorderView: NSView {
        var onShortcut: ((CaptureKeyboardShortcut) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(self)
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }

            guard let shortcut = CaptureKeyboardShortcut.from(event: event) else {
                NSSound.beep()
                return
            }

            onShortcut?(shortcut)
        }
    }
}
