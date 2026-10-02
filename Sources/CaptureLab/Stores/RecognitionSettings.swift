import Foundation

@MainActor
final class RecognitionSettings: ObservableObject {
    @Published var languages: [String] { didSet { defaults?.set(languages, forKey: Self.key) } }
    @Published private(set) var supported: [String] = []
    @Published private(set) var error: String?
    static let key = "recognitionLanguages.v1"
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        languages = defaults?.stringArray(forKey: Self.key) ?? []
        do { supported = try TextRecognitionService.supportedLanguages() }
        catch { self.error = error.localizedDescription }
    }
    func select(_ values: [String]) {
        languages = values.filter { supported.contains($0) }
    }
}
