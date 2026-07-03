import AppKit

extension NSImage {
    var captureLabPixelSize: CGSize {
        if let representation = representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }

    func captureLabCGImage() -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    func captureLabPNGData(annotations: [CaptureAnnotation] = []) -> Data? {
        let image = annotations.isEmpty ? self : renderedWithCaptureLabAnnotations(annotations)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func renderedWithCaptureLabAnnotations(_ annotations: [CaptureAnnotation]) -> NSImage {
        guard !annotations.isEmpty else {
            return self
        }

        let output = NSImage(size: size)
        output.lockFocus()
        defer { output.unlockFocus() }

        draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)

        for annotation in annotations {
            switch annotation.kind {
            case .arrow:
                drawCaptureLabArrow(annotation.imagePoints(in: size), in: size)
            case .line:
                drawCaptureLabLine(annotation.imagePoints(in: size), in: size)
            case .rectangle:
                let rect = annotation.imageRect(in: size)
                let path = NSBezierPath(rect: rect)
                path.lineWidth = max(3, min(size.width, size.height) * 0.004)
                NSColor.systemRed.setStroke()
                path.stroke()
            case .counter:
                drawCaptureLabCounter(annotation.text.isEmpty ? "1" : annotation.text, rect: annotation.imageRect(in: size))
            case .brush:
                drawCaptureLabBrush(annotation.imagePoints(in: size), in: size)
            case .text:
                drawCaptureLabText(annotation.text.isEmpty ? "Text" : annotation.text, rect: annotation.imageRect(in: size), in: size)
            case .highlight:
                drawCaptureLabHighlight(rect: annotation.imageRect(in: size))
            case .mosaic:
                drawCaptureLabMosaic(annotation, in: size)
            }
        }

        return output
    }

    private func drawCaptureLabArrow(_ points: [CGPoint], in imageSize: CGSize) {
        guard points.count >= 2,
              let start = points.first,
              let end = points.last
        else {
            return
        }

        let lineWidth = max(3, min(imageSize.width, imageSize.height) * 0.004)
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = lineWidth
        path.move(to: start)
        path.line(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(14, lineWidth * 4)
        let headAngle: CGFloat = .pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        path.move(to: left)
        path.line(to: end)
        path.line(to: right)

        NSColor.systemRed.setStroke()
        path.stroke()
    }

    private func drawCaptureLabLine(_ points: [CGPoint], in imageSize: CGSize) {
        guard points.count >= 2,
              let start = points.first,
              let end = points.last
        else {
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = max(3, min(imageSize.width, imageSize.height) * 0.004)
        path.move(to: start)
        path.line(to: end)

        NSColor.systemRed.setStroke()
        path.stroke()
    }

    private func drawCaptureLabBrush(_ points: [CGPoint], in imageSize: CGSize) {
        guard let first = points.first, points.count >= 2 else {
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = max(4, min(imageSize.width, imageSize.height) * 0.005)
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }

        NSColor.systemRed.setStroke()
        path.stroke()
    }

    private func drawCaptureLabCounter(_ value: String, rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let diameter = max(16, min(rect.width, rect.height))
        let circleRect = CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let fontSize = max(12, diameter * 0.48)
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

    private func drawCaptureLabText(_ text: String, rect: CGRect, in imageSize: CGSize) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let fontSize = max(14, min(44, rect.height * 0.46))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: paragraph
        ]
        let textRect = rect.insetBy(dx: 2, dy: max(0, (rect.height - fontSize * 1.25) / 2))
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawCaptureLabHighlight(rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        NSColor.systemYellow.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    private func drawCaptureLabMosaic(_ annotation: CaptureAnnotation, in imageSize: CGSize) {
        let rect = annotation.imageRect(in: imageSize)
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        if let pixelated = captureLabPixelatedRegion(normalizedRect: annotation.normalizedRect) {
            pixelated.draw(in: rect, from: NSRect(origin: .zero, size: pixelated.size), operation: .sourceOver, fraction: 1)
            return
        }

        drawCaptureLabMosaicFallback(rect: rect, in: imageSize)
    }

    private func drawCaptureLabMosaicFallback(rect: CGRect, in imageSize: CGSize) {
        let block = max(4, min(imageSize.width, imageSize.height) * 0.01)
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var column = 0
            var x = rect.minX
            while x < rect.maxX {
                let opacity: CGFloat = (row + column).isMultiple(of: 2) ? 0.62 : 0.44
                let tile = CGRect(
                    x: x,
                    y: y,
                    width: min(block, rect.maxX - x),
                    height: min(block, rect.maxY - y)
                )
                NSColor.black.withAlphaComponent(opacity).setFill()
                NSBezierPath(rect: tile).fill()
                x += block
                column += 1
            }
            y += block
            row += 1
        }
    }

    private func captureLabPixelatedRegion(normalizedRect: CGRect) -> NSImage? {
        guard normalizedRect.width > 0,
              normalizedRect.height > 0,
              let source = captureLabCGImage()
        else {
            return nil
        }

        guard let output = CapturePixelation.pixelatedImage(from: source, normalizedRect: normalizedRect) else {
            return nil
        }

        return NSImage(cgImage: output, size: CGSize(width: output.width, height: output.height))
    }
}
