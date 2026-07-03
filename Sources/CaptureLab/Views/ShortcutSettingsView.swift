import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var shortcutStore: CaptureShortcutStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftShortcut: CaptureKeyboardShortcut
    @State private var window: NSWindow?

    init(shortcutStore: CaptureShortcutStore) {
        self.shortcutStore = shortcutStore
        _draftShortcut = State(initialValue: shortcutStore.captureShortcut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.shortcutSettingsTitle)
                        .font(.system(size: 17, weight: .semibold))
                    Text(L10n.shortcutSettingsSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.screenshotShortcut)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ShortcutRecorderView(
                    shortcut: $draftShortcut,
                    cancelAction: close
                )
                .frame(height: 48)

                Text(L10n.shortcutHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()

                Button(L10n.cancel) {
                    close()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.save) {
                    shortcutStore.saveCaptureShortcut(draftShortcut)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draftShortcut.isValid)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(ShortcutSettingsWindowReader(window: $window))
        .onAppear {
            draftShortcut = shortcutStore.captureShortcut
        }
    }

    private func close() {
        if let window {
            window.close()
        } else {
            dismiss()
        }
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
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
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
