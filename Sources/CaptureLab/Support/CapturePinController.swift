import AppKit

@MainActor
final class CapturePinController: NSObject, NSWindowDelegate {
    static let shared = CapturePinController()

    private(set) var windows: [NSWindow] = []

    func pin(image: NSImage, title: String) {
        let snapshot: NSImage
        if let pixels = image.captureLabCGImage() {
            snapshot = NSImage(cgImage: pixels, size: image.size)
        } else {
            snapshot = (image.copy() as? NSImage) ?? image
        }
        let window = CapturePinWindow(image: snapshot, title: title)
        window.delegate = self
        windows.append(window)
        window.center()
        if windows.count > 1 {
            let offset = CGFloat((windows.count - 1) % 8) * 24
            window.setFrameOrigin(NSPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }
}

@MainActor
private final class CapturePinWindow: NSWindow {
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let imageView = NSImageView()

    init(image: NSImage, title: String) {
        let size = Self.initialContentSize(for: image.size)
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.title = title
        identifier = NSUserInterfaceItemIdentifier("CaptureLab.pin.\(UUID().uuidString)")
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = CGSize(width: 260, height: 160)
        isOpaque = false
        backgroundColor = .clear

        let root = NSView()
        root.toolTip = L10n.pinWindowHelp
        contentView = root

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addSubview(imageView)

        let controlsBackground = NSView()
        controlsBackground.wantsLayer = true
        controlsBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        controlsBackground.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controlsBackground)

        let opacityLabel = NSTextField(labelWithString: L10n.pinOpacity)
        opacityLabel.font = .systemFont(ofSize: 11)
        let slider = CapturePinSlider(value: 1, minValue: 0.2, maxValue: 1, target: self, action: #selector(changeOpacity(_:)))
        slider.toolTip = L10n.pinOpacity
        slider.setAccessibilityLabel(L10n.pinOpacity)
        slider.isContinuous = true
        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityValueLabel.alignment = .right
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.pinClose)!, target: self, action: #selector(closePin(_:)))
        closeButton.bezelStyle = .inline
        closeButton.toolTip = L10n.pinClose

        let controls = NSStackView(views: [opacityLabel, slider, opacityValueLabel, closeButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsBackground.addSubview(controls)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: root.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: controlsBackground.topAnchor),
            controlsBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controlsBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controlsBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            controlsBackground.heightAnchor.constraint(equalToConstant: 38),
            controls.leadingAnchor.constraint(equalTo: controlsBackground.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: controlsBackground.trailingAnchor, constant: -10),
            controls.bottomAnchor.constraint(equalTo: controlsBackground.bottomAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    @objc private func changeOpacity(_ sender: NSSlider) {
        imageView.alphaValue = sender.doubleValue
        opacityValueLabel.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
    }

    @objc private func closePin(_ sender: Any?) {
        close()
    }

    private static func initialContentSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 480, height: 360)
        }
        let scale = min(1, 640 / imageSize.width, 480 / imageSize.height)
        return CGSize(width: max(260, imageSize.width * scale), height: max(160, imageSize.height * scale + 38))
    }
}

private final class CapturePinSlider: NSSlider {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.close()
        } else {
            super.keyDown(with: event)
        }
    }
}
