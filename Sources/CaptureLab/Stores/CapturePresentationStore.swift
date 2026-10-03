import Foundation

struct CapturePresentationPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var presentation: CapturePresentation
}

/// Presets store their own embedded background so relocating an imported image
/// cannot silently change a saved style. Writes replace the complete file atomically.
@MainActor
final class CapturePresentationStore: ObservableObject {
    @Published private(set) var presets: [CapturePresentationPreset] = []
    @Published private(set) var errorMessage: String?
    private let url: URL
    private struct Archive: Codable { var version = 1; var presets: [CapturePresentationPreset] }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureLab", isDirectory: true).appendingPathComponent("presentation-presets.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            guard let fileSize = try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= CaptureImageImport.maximumBytes else { throw CapturePresentationError.presetLimit }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.url))
            guard archive.version == 1, archive.presets.count <= 50,
                  Set(archive.presets.map(\.id)).count == archive.presets.count else { throw CapturePresentationError.invalidLayout }
            for preset in archive.presets {
                try preset.presentation.validate()
                try Self.validateName(preset.name)
            }
            presets = archive.presets
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func save(name: String, presentation: CapturePresentation) throws -> CapturePresentationPreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateName(name); try presentation.validate()
        guard presets.count < 50 else { throw CapturePresentationError.presetLimit }
        let preset = CapturePresentationPreset(name: name, presentation: presentation)
        try persist(presets + [preset])
        return preset
    }
    func delete(_ id: UUID) throws { try persist(presets.filter { $0.id != id }) }
    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else { throw CapturePresentationError.invalidPresetName }
    }
    private func persist(_ next: [CapturePresentationPreset]) throws {
        let encoded = try JSONEncoder().encode(Archive(presets: next))
        guard encoded.count <= CaptureImageImport.maximumBytes else { throw CapturePresentationError.presetLimit }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoded.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        presets = next
        errorMessage = nil
    }
}

@MainActor
final class CaptureExportSettingsStore {
    static let key = "captureExportSettings.v1"
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }
    func load() -> CaptureExportSettings {
        guard let data = defaults?.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(CaptureExportSettings.self, from: data),
              settings.quality.isFinite, (0...1).contains(settings.quality), settings.matte.isValid,
              settings.outputSize(for: CGSize(width: 1, height: 1)) != nil else { return CaptureExportSettings() }
        return settings
    }
    func save(_ settings: CaptureExportSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults?.set(data, forKey: Self.key)
    }
}
