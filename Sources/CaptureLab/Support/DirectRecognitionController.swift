import AppKit

@MainActor
final class DirectRecognitionController: ObservableObject {
    enum Kind { case text, qrCode }
    typealias TextOperation = @MainActor (CGImage) async throws -> OCRResult
    typealias QROperation = @MainActor (CGImage) async throws -> [String]
    @Published private(set) var isRunning = false
    @Published private(set) var results: [String] = []
    @Published private(set) var message = ""
    @Published private(set) var failure: String?
    private let pasteboard: NSPasteboard
    private let textOperation: TextOperation
    private let qrOperation: QROperation
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    init(pasteboard: NSPasteboard, text: @escaping TextOperation,
         qr: @escaping QROperation = { try await TextRecognitionService().recognizeQRCodes(in: $0) }) {
        self.pasteboard = pasteboard; textOperation = text; qrOperation = qr
    }
    func start(image: CGImage, kind: Kind) {
        cancel()
        let id = UUID()
        requestID = id
        isRunning = true
        results = []
        failure = nil
        message = L10n.recognizingText
        let textOperation = textOperation, qrOperation = qrOperation
        task = Task { [weak self] in
            do {
                let values: [String]
                if kind == .text {
                    let result = try await textOperation(image)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    values = text.isEmpty ? [] : [text]
                } else { values = try await qrOperation(image) }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.results = values
                self.message = values.isEmpty
                    ? L10n.text(en: "No results found. Clipboard unchanged.", zh: "未识别到内容，剪贴板保持不变。")
                    : L10n.text(en: "Select a result to copy.", zh: "选择识别结果并复制。")
                if kind == .text, let text = values.first { self.copy(text) }
            } catch {
                guard let self, self.requestID == id else { return }
                if !(error is CancellationError) { self.failure = error.localizedDescription }
            }
            guard let self, self.requestID == id else { return }
            self.isRunning = false
            self.task = nil
        }
    }
    func copy(_ text: String) {
        guard results.contains(text), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        message = L10n.ocrTextCopied
    }
    func cancel() {
        requestID = nil
        task?.cancel(); task = nil
        if isRunning { message = L10n.captureCancelled }
        isRunning = false
    }
}
