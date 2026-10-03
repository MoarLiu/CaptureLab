import AppKit

// Optional appearance fields keep projects created before 0.9 readable.
enum CaptureArrowStyle: String, Codable, CaseIterable, Identifiable {
    case open, filled, doubleEnded
    var id: Self { self }
    var title: String {
        switch self {
        case .open: return L10n.text(en: "Open", zh: "开放箭头")
        case .filled: return L10n.text(en: "Filled", zh: "实心箭头")
        case .doubleEnded: return L10n.text(en: "Double-ended", zh: "双向箭头")
        }
    }
}
enum CaptureShapeFill: String, Codable, CaseIterable, Identifiable {
    case stroke, fill, strokeAndFill
    var id: Self { self }
    var title: String {
        switch self {
        case .stroke: return L10n.text(en: "Stroke", zh: "描边")
        case .fill: return L10n.text(en: "Fill", zh: "填充")
        case .strokeAndFill: return L10n.text(en: "Stroke and fill", zh: "描边与填充")
        }
    }
}
enum CaptureFontWeight: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold, heavy
    var id: Self { self }
    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
    var title: String {
        switch self {
        case .regular: return L10n.text(en: "Regular", zh: "常规")
        case .medium: return L10n.text(en: "Medium", zh: "中等")
        case .semibold: return L10n.text(en: "Semibold", zh: "半粗")
        case .bold: return L10n.text(en: "Bold", zh: "粗体")
        case .heavy: return L10n.text(en: "Heavy", zh: "特粗")
        }
    }
}
enum CaptureTextAlignment: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: Self { self }
    var nsAlignment: NSTextAlignment {
        switch self { case .left: return .left; case .center: return .center; case .right: return .right }
    }
    var title: String {
        switch self {
        case .left: return L10n.text(en: "Left", zh: "左对齐")
        case .center: return L10n.text(en: "Center", zh: "居中")
        case .right: return L10n.text(en: "Right", zh: "右对齐")
        }
    }
}
extension CaptureAnnotationAppearance {
    func textFont(size: CGFloat) -> NSFont {
        let weight = fontWeight?.nsWeight ?? .semibold
        guard let fontFamily, !fontFamily.isEmpty else { return .systemFont(ofSize: size, weight: weight) }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: fontFamily,
                                                          .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

/// Shared paths are consumed by both the flipped editor and the image exporter.
enum CaptureAnnotationPaths {
    static func curvePoints(_ points: [CGPoint], steps: Int = 32) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let start = points[0], end = points[1], control = points[2]
        return (0...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps), u = 1 - t
            return CGPoint(x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
                           y: u*u*start.y + 2*u*t*control.y + t*t*end.y)
        }
    }
    static func brush(_ points: [CGPoint], smoothing: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2, smoothing > 0 else {
            points.dropFirst().forEach { path.line(to: $0) }
            return path
        }
        // Catmull-Rom interpolation blends with straight segments. Control points
        // are kept within each segment's bounds, so smoothing cannot overshoot.
        let amount = min(1, max(0, smoothing))
        for i in 0..<(points.count - 1) {
            let a = points[max(0, i - 1)], b = points[i], c = points[i + 1], d = points[min(points.count - 1, i + 2)]
            func control(_ proposed: CGPoint, straight: CGPoint) -> CGPoint {
                CGPoint(x: min(max(straight.x + (proposed.x - straight.x) * amount, min(b.x,c.x)), max(b.x,c.x)),
                        y: min(max(straight.y + (proposed.y - straight.y) * amount, min(b.y,c.y)), max(b.y,c.y)))
            }
            let p = control(CGPoint(x: b.x + (c.x-a.x)/6, y: b.y + (c.y-a.y)/6),
                            straight: CGPoint(x: b.x + (c.x-b.x)/3, y: b.y + (c.y-b.y)/3))
            let q = control(CGPoint(x: c.x - (d.x-b.x)/6, y: c.y - (d.y-b.y)/6),
                            straight: CGPoint(x: c.x - (c.x-b.x)/3, y: c.y - (c.y-b.y)/3))
            path.curve(to: c, controlPoint1: p, controlPoint2: q)
        }
        return path
    }
    static func drawArrow(points: [CGPoint], curved: Bool, style: CaptureAnnotationStyle, alpha: CGFloat = 1) {
        guard points.count >= 2 else { return }
        let start = points[0], end = points[1]
        let path = NSBezierPath()
        path.move(to: start)
        if curved, points.count >= 3 {
            let control = points[2]
            path.curve(to: end,
                       controlPoint1: CGPoint(x: start.x + (control.x-start.x)*2/3, y: start.y + (control.y-start.y)*2/3),
                       controlPoint2: CGPoint(x: end.x + (control.x-end.x)*2/3, y: end.y + (control.y-end.y)*2/3))
        } else { path.line(to: end) }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.lineWidth
        style.color.withAlphaComponent(alpha).setStroke()
        style.color.withAlphaComponent(alpha).setFill()
        path.stroke()
        func head(at tip: CGPoint, from tail: CGPoint) {
            let angle = atan2(tip.y-tail.y, tip.x-tail.x)
            let left = CGPoint(x: tip.x-style.arrowHeadLength*cos(angle-style.arrowHeadAngle), y: tip.y-style.arrowHeadLength*sin(angle-style.arrowHeadAngle))
            let right = CGPoint(x: tip.x-style.arrowHeadLength*cos(angle+style.arrowHeadAngle), y: tip.y-style.arrowHeadLength*sin(angle+style.arrowHeadAngle))
            let head = NSBezierPath(); head.move(to: left); head.line(to: tip); head.line(to: right)
            head.lineWidth = style.lineWidth; head.lineCapStyle = .round; head.lineJoinStyle = .round
            if style.appearance.arrowStyle == .filled { head.close(); head.fill() } else { head.stroke() }
        }
        let control = curved && points.count >= 3 ? points[2] : start
        // When a quadratic control point coincides with an endpoint its
        // first derivative is zero there; the remaining endpoint still gives
        // the limiting tangent of the curve.
        head(at: end, from: control == end ? start : control)
        if style.appearance.arrowStyle == .doubleEnded {
            let tail = curved && points.count >= 3 ? points[2] : end
            head(at: start, from: tail == start ? end : tail)
        }
    }
    static func drawShape(rect: CGRect, kind: CaptureAnnotation.Kind, style: CaptureAnnotationStyle, alpha: CGFloat = 1) {
        let path = kind == .ellipse ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        let fill = style.appearance.shapeFill ?? (kind == .filledRectangle ? .fill : .stroke)
        if fill != .stroke {
            (style.appearance.fillColor?.nsColor ?? style.color).withAlphaComponent(alpha).setFill()
            path.fill()
        }
        if fill != .fill { path.lineWidth = style.lineWidth; style.color.withAlphaComponent(alpha).setStroke(); path.stroke() }
    }
    static func drawSpotlight(rect: CGRect, imageRect: CGRect, style: CaptureAnnotationStyle, alpha: CGFloat = 1) {
        let path = NSBezierPath(rect: imageRect)
        path.append(NSBezierPath(ovalIn: rect)); path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(min(0.95, max(0.05, style.appearance.spotlightOpacity ?? 0.6)) * alpha).setFill()
        path.fill()
    }
    static func drawText(_ text: String, rect: CGRect, style: CaptureAnnotationStyle, alpha: CGFloat = 1) {
        guard rect.width > 0, rect.height > 0 else { return }
        if let background = style.appearance.textBackgroundColor {
            background.nsColor.withAlphaComponent(alpha).setFill(); NSBezierPath(rect: rect).fill()
        }
        if let border = style.appearance.textBorderColor {
            border.nsColor.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath(rect: rect); path.lineWidth = style.lineWidth; path.stroke()
        }
        let size = style.textFontSize(for: rect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.appearance.textAlignment?.nsAlignment ?? .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: style.appearance.textFont(size: size),
            .foregroundColor: style.color.withAlphaComponent(alpha), .paragraphStyle: paragraph]
        let textRect = rect.insetBy(dx: style.textInset, dy: max(0, (rect.height-size*1.25)/2))
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

extension CaptureAnnotationAppearance {
    var isValid: Bool {
        func inRange(_ value: CGFloat?, _ range: ClosedRange<CGFloat>) -> Bool {
            value.map { $0.isFinite && range.contains($0) } ?? true
        }
        func validColor(_ color: CaptureAnnotationColor?) -> Bool {
            guard let color else { return true }
            return [color.red, color.green, color.blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
        return inRange(lineWidth, 0.1...1024) && inRange(fontSize, 1...4096)
            && inRange(blurRadius, 1...60) && inRange(spotlightOpacity, 0.05...0.95)
            && inRange(brushSmoothing, 0...1) && (fontFamily?.utf8.count ?? 0) <= 256
            && [color, fillColor, textBackgroundColor, textBorderColor].allSatisfy(validColor)
    }
}
