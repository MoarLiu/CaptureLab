import AppKit
import SwiftUI

/// Retains SwiftUI's window delegate while adding a synchronous recovery gate.
/// Failed persistence keeps the editor and its undo stack alive for retry.
struct CaptureDocumentCloseGuard: NSViewRepresentable {
    let model: CaptureLabViewModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attach = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.detach() }

    final class AttachmentView: NSView {
        var attach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(window) }
    }

    // NSObject forwarding is called synchronously by AppKit on the main thread.
    private struct DelegateReference: @unchecked Sendable { let value: (any NSWindowDelegate)? }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let model: CaptureLabViewModel
        private weak var window: NSWindow?
        private weak var original: (any NSWindowDelegate)?
        init(model: CaptureLabViewModel) { self.model = model }
        func attach(_ window: NSWindow?) {
            guard let window, self.window !== window || window.delegate !== self else { return }
            detach()
            self.window = window
            original = window.delegate
            window.delegate = self
        }
        func detach() {
            if window?.delegate === self { window?.delegate = original }
            window = nil
            original = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.preserveDocumentBeforeReplacement() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { original?.responds(to: selector) ?? false }
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            MainActor.assumeIsolated { DelegateReference(value: original) }.value
        }
    }
}
