import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    private let toolbarHeight: CGFloat = 52

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 1_080, height: 620)
        alignTrafficLights(in: window)
    }

    private func alignTrafficLights(in window: NSWindow) {
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }

        guard buttons.count == 3 else {
            return
        }

        let closeButton = buttons[0]
        let spacing = max(buttons[1].frame.minX - buttons[0].frame.minX, 20)
        let originX = closeButton.frame.minX
        let originY: CGFloat = 0

        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(
                x: originX + CGFloat(index) * spacing,
                y: originY
            ))
        }
    }
}

struct CaptureWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CaptureWindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CaptureWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
