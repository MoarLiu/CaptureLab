import CoreGraphics

enum CaptureCropPreset: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, sixteenNine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return L10n.text(en: "Free", zh: "自由")
        case .original: return L10n.text(en: "Original", zh: "原比例")
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        }
    }
    func ratio(in size: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return size.width / size.height
        case .square: return 1
        case .fourThree: return 4 / 3
        case .sixteenNine: return 16 / 9
        }
    }
}

enum CaptureCropGeometry {
    static func selection(anchor: CGPoint, current: CGPoint, size: CGSize, ratio: CGFloat?) -> CGRect {
        let start = anchor.clampedToUnit()
        let end = current.clampedToUnit()
        let dx: CGFloat = end.x >= start.x ? 1 : -1
        let dy: CGFloat = end.y >= start.y ? 1 : -1
        var width = abs(end.x - start.x) * size.width
        var height = abs(end.y - start.y) * size.height
        if let ratio, ratio.isFinite, ratio > 0 {
            // Fit the requested ratio within both the drag and image bounds.
            width = max(width, height * ratio)
            width = min(width, (dx > 0 ? 1 - start.x : start.x) * size.width,
                        (dy > 0 ? 1 - start.y : start.y) * size.height * ratio)
            height = width / ratio
        }
        return CGRect(x: dx > 0 ? start.x : start.x - width / size.width,
                      y: dy > 0 ? start.y : start.y - height / size.height,
                      width: width / size.width, height: height / size.height).clampedToUnit()
    }

    static func exactSelection(size: CGSize, canvasSize: CGSize, center: CGPoint) -> CGRect {
        let width = min(size.width, canvasSize.width)
        let height = min(size.height, canvasSize.height)
        let x = min(max((center.x * canvasSize.width - width / 2).rounded(), 0), canvasSize.width - width)
        let y = min(max((center.y * canvasSize.height - height / 2).rounded(), 0), canvasSize.height - height)
        return CGRect(x: x / canvasSize.width, y: y / canvasSize.height,
                      width: width / canvasSize.width, height: height / canvasSize.height)
    }

    static func moving(_ selection: CGRect, dx: CGFloat, dy: CGFloat, snap: CGSize, pixelSize: CGSize? = nil) -> CGRect {
        var rect = selection
        if let size = pixelSize, let pixels = CaptureImageCrop.pixelRect(selection, pixelSize: size) {
            rect = CGRect(x: pixels.minX / size.width, y: pixels.minY / size.height,
                          width: pixels.width / size.width, height: pixels.height / size.height)
        }
        var result = rect.offsetBy(dx: min(max(dx, -rect.minX), 1 - rect.maxX),
                                   dy: min(max(dy, -rect.minY), 1 - rect.maxY))
        if result.minX < snap.width { result.origin.x = 0 }
        else if 1 - result.maxX < snap.width { result.origin.x = 1 - result.width }
        if result.minY < snap.height { result.origin.y = 0 }
        else if 1 - result.maxY < snap.height { result.origin.y = 1 - result.height }
        if let size = pixelSize {
            result.origin.x = (result.minX * size.width).rounded() / size.width
            result.origin.y = (result.minY * size.height).rounded() / size.height
        }
        return result
    }
}
