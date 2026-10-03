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
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.interpolationQuality = CGInterpolationQuality.high
        graphicsContext.cgContext.draw(source, in: bounds)

        for annotation in annotations {
            let style = CaptureAnnotationStyle(
                sourcePixelSize: pixelSize,
                renderedImageSize: pixelSize,
                appearance: annotation.appearance
            )
            switch annotation.kind {
            case .arrow, .curvedArrow:
                CaptureAnnotationPaths.drawArrow(points: annotation.imagePoints(in: pixelSize), curved: annotation.kind == .curvedArrow, style: style)
            case .line:
                drawCaptureLabLine(annotation.imagePoints(in: pixelSize), style: style)
            case .rectangle, .ellipse, .filledRectangle:
                CaptureAnnotationPaths.drawShape(rect: annotation.imageRect(in: pixelSize), kind: annotation.kind, style: style)
            case .spotlight:
                CaptureAnnotationPaths.drawSpotlight(rect: annotation.imageRect(in: pixelSize), imageRect: bounds, style: style)
            case .blur:
                // Read the already-rendered stack so blur cannot reveal an
                // earlier mosaic or a hidden image-layer pixel. Snapshot the
                // CGContext, not bitmap.cgImage: the latter caches an image
                // before the effect and would return stale pixels at export.
                graphicsContext.flushGraphics()
                guard let current = graphicsContext.cgContext.makeImage(),
                      let blurred = CaptureBlur.image(from: current, normalizedRect: annotation.normalizedRect,
                                                       radius: annotation.appearance.blurRadius ?? 12) else { return nil }
                graphicsContext.cgContext.draw(blurred, in: annotation.imageRect(in: pixelSize))
            case .counter:
                drawCaptureLabCounter(
                    annotation.text.isEmpty ? "1" : annotation.text,
                    rect: annotation.imageRect(in: pixelSize),
                    style: style
                )
            case .brush:
                drawCaptureLabBrush(annotation.imagePoints(in: pixelSize), style: style)
            case .text:
                CaptureAnnotationPaths.drawText(
                    annotation.text.isEmpty ? L10n.defaultAnnotationText : annotation.text,
                    rect: annotation.imageRect(in: pixelSize),
                    style: style
                )
            case .highlight:
                drawCaptureLabHighlight(rect: annotation.imageRect(in: pixelSize), style: style)
            case .mosaic:
                graphicsContext.flushGraphics()
                guard let current = graphicsContext.cgContext.makeImage() else { return nil }
                drawCaptureLabMosaic(annotation, source: current, imageSize: pixelSize)
            }
        }

        return bitmap
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

        style.color.setStroke()
        path.stroke()
    }

    private func drawCaptureLabBrush(_ points: [CGPoint], style: CaptureAnnotationStyle) {
        guard points.count >= 2 else {
            return
        }

        let path = CaptureAnnotationPaths.brush(points, smoothing: style.appearance.brushSmoothing ?? 0)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.brushWidth

        style.color.setStroke()
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
        style.color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let fontSize = style.counterFontSize(for: diameter, text: value)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: style.counterTextColor,
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

    private func drawCaptureLabHighlight(rect: CGRect, style: CaptureAnnotationStyle) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        style.highlightColor.withAlphaComponent(0.42).setFill()
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
