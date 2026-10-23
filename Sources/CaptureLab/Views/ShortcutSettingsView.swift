import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var shortcutStore: CaptureShortcutStore
    @ObservedObject var controller: GlobalHotKeyController
    @ObservedObject var session: CaptureSettingsSession
    let onSave: (CaptureAction, CaptureKeyboardShortcut?) -> String?
    @State private var errors: [CaptureAction: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CaptureSettingsNote(text: L10n.text(en: "Click a shortcut to record a new combination. Press Escape to cancel.", zh: "点击快捷键录制新组合，按 Esc 取消。"))
            group(L10n.text(en: "Capture", zh: "截图"), actions: [.region, .window, .fullScreen, .lastRegion, .delayedRegion, .launcher])
            group(L10n.text(en: "Text & QR Codes", zh: "文字与二维码"), actions: [.text, .qrCode])
        }
        .onChange(of: session.recordingAction) { action in
            controller.recordShortcut = action.map { target in { value in
                guard session.recordingAction == target, session.section == .shortcuts else { return }
                save(value, for: target)
            } }
        }
        .onDisappear { session.recordingAction = nil; controller.recordShortcut = nil }
    }
    private func group(_ title: String, actions: [CaptureAction]) -> some View {
        CaptureSettingsGroup(title: title) {
            ForEach(actions) { action in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.title).font(.system(size: 13))
                            Text(registrationStatus(for: action)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if session.recordingAction == action {
                            ShortcutRecorderBridge(onShortcut: {
                                if session.recordingAction == action { save($0, for: action) }
                            }, onCancel: {
                                if session.recordingAction == action { session.recordingAction = nil }
                            })
                                .frame(width: 174, height: 32)
                                .overlay { Text(L10n.text(en: "Press shortcut…", zh: "按下组合键…")).font(.system(size: 12)).allowsHitTesting(false) }
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1) }
                        } else {
                            Button {
                                errors[action] = nil
                                session.recordingAction = action
                            } label: {
                                Text(shortcutStore.shortcut(for: action)?.displayTitle ?? L10n.text(en: "Record shortcut", zh: "录制快捷键"))
                                    .font(.system(size: 13, weight: shortcutStore.shortcut(for: action) == nil ? .regular : .medium))
                                    .frame(width: 166, height: 28)
                            }.buttonStyle(.bordered)
                                .accessibilityLabel(action.title + ": " + (shortcutStore.shortcut(for: action)?.displayTitle ?? L10n.text(en: "Not set", zh: "未设置")))
                        }
                        Button { save(nil, for: action) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).disabled(action == .region || shortcutStore.shortcut(for: action) == nil)
                            .accessibilityLabel(L10n.text(en: "Clear shortcut for \(action.title)", zh: "清除\(action.title)快捷键"))
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                    if let error = errors[action] ?? controller.actionErrors[action] {
                        CaptureSettingsNote(text: error, isError: true).padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
                .background(session.focusedShortcut == action ? Color.accentColor.opacity(0.06) : .clear)
                .accessibilityElement(children: .contain)
                .id(action)
                if action != actions.last { Divider().padding(.horizontal, 16) }
            }
        }
    }
    private func registrationStatus(for action: CaptureAction) -> String {
        if let registered = controller.registeredShortcut(for: action) {
            return L10n.text(en: "Active: \(registered.displayTitle)", zh: "已注册：\(registered.displayTitle)")
        }
        if controller.actionErrors[action] != nil { return L10n.text(en: "Unavailable — see the reason below", zh: "注册失败，原因见下方") }
        return shortcutStore.shortcut(for: action) == nil
            ? L10n.text(en: "Not set", zh: "未设置")
            : L10n.text(en: "Not registered", zh: "尚未注册")
    }
    private func save(_ value: CaptureKeyboardShortcut?, for action: CaptureAction) {
        if let value, let conflict = shortcutStore.conflict(for: value, action: action) {
            errors[action] = L10n.text(en: "Already assigned to \(conflict.title).", zh: "已用于“\(conflict.title)”。")
            session.recordingAction = nil
            return
        }
        var failure: String?
        let saved = shortcutStore.save(value, for: action) {
            failure = onSave(action, value)
            return failure == nil
        }
        errors[action] = saved ? nil : failure ?? L10n.text(en: "This shortcut could not be saved. Try another combination.", zh: "无法保存此快捷键，请尝试其他组合。")
        session.recordingAction = nil
    }
}

private struct ShortcutRecorderBridge: NSViewRepresentable {
    let onShortcut: (CaptureKeyboardShortcut) -> Void
    let onCancel: () -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onShortcut = onShortcut; view.onCancel = onCancel
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textField)
        view.setAccessibilityLabel(L10n.text(en: "Recording shortcut. Press Escape to cancel.", zh: "正在录制快捷键，按 Esc 取消。"))
        return view
    }
    func updateNSView(_ view: RecorderView, context: Context) { view.onShortcut = onShortcut; view.onCancel = onCancel }
    final class RecorderView: NSView {
        var onShortcut: ((CaptureKeyboardShortcut) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.superview != nil else { return }
                window.makeFirstResponder(self)
            }
        }
        override func resignFirstResponder() -> Bool { onCancel?(); return true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }
            guard let value = CaptureKeyboardShortcut.from(event: event) else { NSSound.beep(); return }
            onShortcut?(value)
        }
    }
}
