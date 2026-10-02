import AppKit

@MainActor
final class PreciseScreenCapture {
    static let shared = PreciseScreenCapture()
    let store: CaptureRegionStore
    private let selector = CaptureRegionSelector()
    init(store: CaptureRegionStore? = nil) { self.store = store ?? CaptureRegionStore() }

    func capture(_ mode: CaptureMode) async throws -> URL {
        if mode == .fullScreen || mode == .window {
            return try await Task.detached(priority: .userInitiated) { try ScreenCaptureService().captureFile(mode: mode) }.value
        }
        if case .delayedRegion(let seconds) = mode {
            try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 60))) * 1_000_000_000)
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureLabError.captureFailed(L10n.text(en: "Allow CaptureLab in System Settings → Privacy & Security → Screen Recording, then try again.", zh: "请在系统设置 → 隐私与安全 → 屏幕录制中允许 CaptureLab，然后重试。"))
        }
        let displays = CaptureDisplay.current()
        let rect: CGRect
        let frozen = mode == .frozenRegion
        var frames: [String: CGImage] = [:]
        if mode == .lastRegion {
            guard let saved = store.lastRegion?.resolve(in: displays) else {
                throw CaptureLabError.captureFailed(L10n.invalidLastRegion)
            }
            rect = saved
        } else {
            frames = try snapshot(displays)
            rect = try await selector.select(displays: displays, frames: frames, frozen: frozen)
        }
        try Task.checkCancellation()
        guard CaptureDisplay.current() == displays else { throw CaptureLabError.captureFailed(L10n.invalidLastRegion) }
        if !frozen {
            // The selection and options panels must leave WindowServer before acquisition.
            try await Task.sleep(nanoseconds: 150_000_000)
            frames = try snapshot(displays)
        }
        guard CaptureDisplay.current() == displays,
              let image = Self.compose(rect: rect, displays: displays, frames: frames),
              let data = NSImage(cgImage: image, size: .zero).captureLabPNGData(),
              let saved = SavedCaptureRegion(rect: rect, displays: displays) else {
            throw CaptureLabError.imageExportFailed
        }
        let url = try ScreenCaptureLifecycle.shared.captureDirectory().appendingPathComponent("capture-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
        store.save(saved) // Only completed acquisition replaces the last successful region.
        return url
    }

    private func snapshot(_ displays: [CaptureDisplay]) throws -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for display in displays {
            guard let uuid = CFUUIDCreateFromString(nil, display.id as CFString),
                  let image = CGDisplayCreateImage(CGDisplayGetDisplayIDFromUUID(uuid)) else {
                throw CaptureLabError.captureFailed(L10n.noCaptureFileCreated)
            }
            result[display.id] = image
        }
        return result
    }

    static func compose(rect: CGRect, displays: [CaptureDisplay], frames: [String: CGImage]) -> CGImage? {
        guard let size = PreciseCaptureGeometry.outputSize(rect, displays: displays),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sx = size.width / rect.width, sy = size.height / rect.height
        for display in displays where display.frame.intersection(rect).hasPositiveArea {
            guard let image = frames[display.id],
                  image.width == display.pixelWidth,
                  image.height == display.pixelHeight else { return nil }
            let part = rect.intersection(display.frame)
            let source = PreciseCaptureGeometry.sourceRect(rect, display: display, imageSize: CGSize(width: image.width, height: image.height))
            guard let crop = image.cropping(to: source) else { return nil }
            context.draw(crop, in: CGRect(x: (part.minX - rect.minX) * sx, y: (part.minY - rect.minY) * sy,
                width: part.width * sx, height: part.height * sy))
        }
        return context.makeImage()
    }
}
