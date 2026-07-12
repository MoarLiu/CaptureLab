import AppKit
import SwiftUI

extension View {
    func captureLabWindowCloseShortcuts() -> some View {
        background(WindowCloseShortcutInstaller())
    }
}

extension NSAlert {
    func captureLabRunModal() -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let window = self?.window,
                  event.window === window,
                  CaptureLabCloseShortcut.matches(event)
            else {
                return event
            }

            window.close()
            NSApp.stopModal(withCode: .cancel)
            return nil
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        return runModal()
    }
}

private struct WindowCloseShortcutInstaller: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                let matchesCloseShortcut = CaptureLabCloseShortcut.matches(event)
                // AppKit invokes local event monitors on the application thread.
                // State that contract explicitly so Swift 6 can preserve the
                // synchronous close-and-consume behavior without actor leakage.
                let didClose = MainActor.assumeIsolated { () -> Bool in
                    guard let self,
                          let window = self.view?.window,
                          eventWindowID == ObjectIdentifier(window),
                          matchesCloseShortcut
                    else {
                        return false
                    }

                    window.close()
                    return true
                }
                return didClose ? nil : event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

private enum CaptureLabCloseShortcut {
    static func matches(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            return true
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option)
        else {
            return false
        }

        return event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
