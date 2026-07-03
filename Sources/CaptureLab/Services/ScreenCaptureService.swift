import Foundation

enum CaptureLabError: LocalizedError {
    case captureCancelled
    case captureFailed(String)
    case imageLoadFailed
    case imageExportFailed
    case ocrImageUnavailable

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            return L10n.captureCancelled
        case .captureFailed(let message):
            return message
        case .imageLoadFailed:
            return L10n.imageLoadFailed
        case .imageExportFailed:
            return L10n.imageExportFailed
        case .ocrImageUnavailable:
            return L10n.ocrImageUnavailable
        }
    }
}

struct ScreenCaptureService {
    func captureInteractiveRegionFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CaptureLabError.captureFailed(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            if process.terminationStatus == 0 {
                throw CaptureLabError.captureFailed(L10n.noCaptureFileCreated)
            }
            throw CaptureLabError.captureCancelled
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw CaptureLabError.captureCancelled
        }

        return url
    }
}
