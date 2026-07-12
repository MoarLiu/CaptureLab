import AppKit

extension NSImage {
    var captureLabPixelSize: CGSize {
        if let source = captureLabCGImage() {
            return CGSize(width: source.width, height: source.height)
        }
        if let representation = representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }) {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }

    func captureLabCGImage() -> CGImage? {
        let bitmapRepresentations = representations
            .compactMap { $0 as? NSBitmapImageRep }
            .sorted { lhs, rhs in
                lhs.pixelsWide * lhs.pixelsHigh > rhs.pixelsWide * rhs.pixelsHigh
            }
        if let source = bitmapRepresentations.compactMap(\.cgImage).first {
            return source
        }

        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    func captureLabPNGData(annotations: [CaptureAnnotation] = []) -> Data? {
        guard let source = captureLabCGImage() else {
            return nil
        }

        let bitmap: NSBitmapImageRep
        if annotations.isEmpty {
            bitmap = NSBitmapImageRep(cgImage: source)
        } else {
            guard let rendered = captureLabRenderedBitmap(source: source, annotations: annotations) else {
                return nil
            }
            bitmap = rendered
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func renderedWithCaptureLabAnnotations(_ annotations: [CaptureAnnotation]) -> NSImage? {
        renderedWithCaptureLabAnnotations(annotations) { source, annotations in
            captureLabRenderedBitmap(source: source, annotations: annotations)
        }
    }

    func renderedWithCaptureLabAnnotations(
        _ annotations: [CaptureAnnotation],
        bitmapRenderer: (CGImage, [CaptureAnnotation]) -> NSBitmapImageRep?
    ) -> NSImage? {
        guard !annotations.isEmpty else {
            return self
        }
        guard let source = captureLabCGImage(),
              let bitmap = bitmapRenderer(source, annotations)
        else {
            // An annotation can be a privacy boundary (notably mosaic). Never
            // turn a rendering/allocation failure into a successful copy of the
            // unredacted source image.
            return nil
        }

        let logicalSize = size.width > 0 && size.height > 0
            ? size
            : CGSize(width: source.width, height: source.height)
        bitmap.size = logicalSize
        let output = NSImage(size: logicalSize)
        output.addRepresentation(bitmap)
        return output
    }

    private func captureLabRenderedBitmap(
        source: CGImage,
        annotations: [CaptureAnnotation]
    ) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.width,
            pixelsHigh: source.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let pixelSize = CGSize(width: source.width, height: source.height)
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let style = CaptureAnnotationStyle(
            sourcePixelSize: pixelSize,
            renderedImageSize: pixelSize
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.interpolationQuality = CGInterpolationQuality.high
        graphicsContext.cgContext.draw(source, in: bounds)

        for annotation in annotations {
            switch annotation.kind {
            case .arrow:
                drawCaptureLabArrow(annotation.imagePoints(in: pixelSize), style: style)
            case .line:
                drawCaptureLabLine(annotation.imagePoints(in: pixelSize), style: style)
            case .rectangle:
                let path = NSBezierPath(rect: annotation.imageRect(in: pixelSize))
                path.lineWidth = style.lineWidth
                NSColor.systemRed.setStroke()
                path.stroke()
            case .counter:
                drawCaptureLabCounter(
                    annotation.text.isEmpty ? "1" : annotation.text,
                    rect: annotation.imageRect(in: pixelSize),
                    style: style
                )
            case .brush:
                drawCaptureLabBrush(annotation.imagePoints(in: pixelSize), style: style)
            case .text:
                drawCaptureLabText(
                    annotation.text.isEmpty ? L10n.defaultAnnotationText : annotation.text,
                    rect: annotation.imageRect(in: pixelSize),
                    style: style
                )
            case .highlight:
                drawCaptureLabHighlight(rect: annotation.imageRect(in: pixelSize), style: style)
            case .mosaic:
                drawCaptureLabMosaic(annotation, source: source, imageSize: pixelSize)
            }
        }

        return bitmap
    }

    private func drawCaptureLabArrow(_ points: [CGPoint], style: CaptureAnnotationStyle) {
        guard points.count >= 2,
              let start = points.first,
              let end = points.last
        else {
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.lineWidth
        path.move(to: start)
        path.line(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let left = CGPoint(
            x: end.x - style.arrowHeadLength * cos(angle - style.arrowHeadAngle),
            y: end.y - style.arrowHeadLength * sin(angle - style.arrowHeadAngle)
        )
        let right = CGPoint(
            x: end.x - style.arrowHeadLength * cos(angle + style.arrowHeadAngle),
            y: end.y - style.arrowHeadLength * sin(angle + style.arrowHeadAngle)
        )
        path.move(to: left)
        path.line(to: end)
        path.line(to: right)

        NSColor.systemRed.setStroke()
        path.stroke()
    }

    private func drawCaptureLabLine(_ points: [CGPoint], style: CaptureAnnotationStyle) {
        guard points.count >= 2,
              let start = points.first,
              let end = points.last
        else {
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.lineWidth
        path.move(to: start)
        path.line(to: end)

        NSColor.systemRed.setStroke()
        path.stroke()
    }

    private func drawCaptureLabBrush(_ points: [CGPoint], style: CaptureAnnotationStyle) {
        guard let first = points.first, points.count >= 2 else {
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.brushWidth
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }

        NSColor.systemRed.setStroke()
        path.stroke()
    }

    private func drawCaptureLabCounter(
        _ value: String,
        rect: CGRect,
        style: CaptureAnnotationStyle
    ) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let diameter = max(style.minimumCounterDiameter, min(rect.width, rect.height))
        let circleRect = CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let fontSize = style.counterFontSize(for: diameter)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let textHeight = fontSize * 1.18
        let textRect = CGRect(
            x: circleRect.minX,
            y: circleRect.midY - textHeight / 2,
            width: circleRect.width,
            height: textHeight
        )
        (value as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawCaptureLabText(
        _ text: String,
        rect: CGRect,
        style: CaptureAnnotationStyle
    ) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let fontSize = style.textFontSize(for: rect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: paragraph
        ]
        let textRect = rect.insetBy(
            dx: style.textInset,
            dy: max(0, (rect.height - fontSize * 1.25) / 2)
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawCaptureLabHighlight(rect: CGRect, style: CaptureAnnotationStyle) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        NSColor.systemYellow.withAlphaComponent(0.42).setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: style.highlightCornerRadius,
            yRadius: style.highlightCornerRadius
        ).fill()
    }

    private func drawCaptureLabMosaic(
        _ annotation: CaptureAnnotation,
        source: CGImage,
        imageSize: CGSize
    ) {
        let rect = annotation.imageRect(in: imageSize)
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        if let pixelated = CapturePixelation.pixelatedImage(
            from: source,
            normalizedRect: annotation.normalizedRect
        ) {
            let image = NSImage(
                cgImage: pixelated,
                size: CGSize(width: pixelated.width, height: pixelated.height)
            )
            image.draw(
                in: rect,
                from: NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: CaptureAnnotationStyle.mosaicOpacity
            )
            return
        }

        // Invalid images and allocation failures must never leave the sensitive
        // source visible under a decorative translucent overlay.
        NSColor.black.setFill()
        NSBezierPath(rect: rect).fill()
    }
}
