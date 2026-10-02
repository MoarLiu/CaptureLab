import AppKit

struct CaptureDisplay: Codable, Equatable {
    var id: String
    var frame: CGRect // Global AppKit points, bottom-left origin.
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: CGFloat { CGFloat(pixelWidth) / frame.width }

    @MainActor static func current() -> [CaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let mode = CGDisplayCopyDisplayMode(number.uint32Value) else { return nil }
            // CGDisplayPixelsWide/High can report logical dimensions in HiDPI modes.
            return CaptureDisplay(id: CFUUIDCreateString(nil, uuid) as String, frame: screen.frame,
                pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight)
        }
    }
}

struct SavedCaptureRegion: Codable, Equatable {
    var anchorID: String
    var localRect: CGRect
    var displays: [CaptureDisplay]

    init?(rect: CGRect, displays: [CaptureDisplay]) {
        let intersecting = displays.filter { $0.frame.intersection(rect).hasPositiveArea }
        guard let anchor = intersecting.first, PreciseCaptureGeometry.outputSize(rect, displays: displays) != nil else { return nil }
        anchorID = anchor.id
        localRect = rect.offsetBy(dx: -anchor.frame.minX, dy: -anchor.frame.minY)
        self.displays = intersecting
    }

    func resolve(in current: [CaptureDisplay]) -> CGRect? {
        guard displays.allSatisfy({ current.contains($0) }),
              let anchor = current.first(where: { $0.id == anchorID }) else { return nil }
        let rect = localRect.offsetBy(dx: anchor.frame.minX, dy: anchor.frame.minY)
        // Adding a screen that now occupies a former gap also invalidates the old region.
        guard Set(current.filter { $0.frame.intersection(rect).hasPositiveArea }.map(\.id)) == Set(displays.map(\.id)),
              PreciseCaptureGeometry.outputSize(rect, displays: current) != nil else { return nil }
        return rect
    }
}

@MainActor
final class CaptureRegionStore {
    private let defaults: UserDefaults?
    private(set) var lastRegion: SavedCaptureRegion?
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: "lastCaptureRegion.v1") {
            lastRegion = try? JSONDecoder().decode(SavedCaptureRegion.self, from: data)
        }
    }
    func save(_ region: SavedCaptureRegion) {
        lastRegion = region
        defaults?.set(try? JSONEncoder().encode(region), forKey: "lastCaptureRegion.v1")
    }
}

enum PreciseCaptureGeometry {
    static let maximumPixels = 80_000_000.0

    static func outputSize(_ rect: CGRect, displays: [CaptureDisplay]) -> CGSize? {
        guard rect.hasPositiveArea, rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        let intersecting = displays.filter { $0.frame.intersection(rect).hasPositiveArea }
        guard let scale = intersecting.map(\.scale).max(), scale.isFinite, scale > 0 else { return nil }
        let desktop = displays.reduce(CGRect.null) { $0.union($1.frame) }
        guard desktop.contains(rect) else { return nil }
        let size = CGSize(width: ceil(rect.width * scale), height: ceil(rect.height * scale))
        guard size.width * size.height <= maximumPixels, size.width <= 32_768, size.height <= 32_768 else { return nil }
        return size
    }

    /// CGImage cropping uses top-left pixels, unlike AppKit's global coordinates.
    static func sourceRect(_ rect: CGRect, display: CaptureDisplay, imageSize: CGSize) -> CGRect {
        let part = rect.intersection(display.frame)
        guard part.hasPositiveArea else { return .null }
        let sx = imageSize.width / display.frame.width
        let sy = imageSize.height / display.frame.height
        return CGRect(x: (part.minX - display.frame.minX) * sx,
                      y: (display.frame.maxY - part.maxY) * sy,
                      width: part.width * sx, height: part.height * sy).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func constrainedRect(from start: CGPoint, to end: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        var dx = end.x - start.x
        var dy = end.y - start.y
        if let ratio, ratio.isFinite, ratio > 0 {
            let availableWidth = max(0, dx < 0 ? start.x - bounds.minX : bounds.maxX - start.x)
            let availableHeight = max(0, dy < 0 ? start.y - bounds.minY : bounds.maxY - start.y)
            let width = min(abs(dx), abs(dy) * ratio, availableWidth, availableHeight * ratio)
            dx = (dx < 0 ? -1 : 1) * width
            dy = (dy < 0 ? -1 : 1) * width / ratio
        }
        return CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy)).intersection(bounds)
    }

    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat, bounds: CGRect) -> CGRect {
        CGRect(x: min(max(bounds.minX, rect.minX + dx), bounds.maxX - rect.width),
               y: min(max(bounds.minY, rect.minY + dy), bounds.maxY - rect.height), width: rect.width, height: rect.height)
    }
}

extension CGRect {
    var hasPositiveArea: Bool { !isNull && !isInfinite && width > 0 && height > 0 }
}
