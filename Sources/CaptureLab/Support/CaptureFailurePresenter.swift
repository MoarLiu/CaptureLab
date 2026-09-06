import AppKit

/// Error presentation cannot depend on the editor window being open: global
/// screenshot shortcuts also run while CaptureLab is a menu bar accessory.
@MainActor
final class CaptureFailurePresenter {
    static let shared = CaptureFailurePresenter()

    private var pending: [(title: String, message: String)] = []
    private var isPresenting = false

    func present(title: String, message: String) {
        pending.append((title, message))
        guard !isPresenting else { return }
        isPresenting = true
        // Let the operation finish its state transitions before entering the
        // modal run loop. Queue simultaneous failures instead of nesting alerts.
        DispatchQueue.main.async { [self] in
            while !pending.isEmpty {
                let failure = pending.removeFirst()
                let alert = Self.makeAlert(title: failure.title, message: failure.message)
                NSApp.activate(ignoringOtherApps: true)
                _ = alert.captureLabRunModal()
            }
            isPresenting = false
        }
    }

    static func makeAlert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.ok)
        return alert
    }
}
