import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class CaptureLabViewModel: ObservableObject {
    @Published private(set) var document: CaptureDocument?
    @Published var annotations: [CaptureAnnotation] = [] {
        didSet {
            trackAnnotationChange(from: oldValue, to: annotations)
        }
    }
    @Published var selectedTool: CaptureTool = .select
    @Published var ocrText = ""
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecognizingText = false
    @Published private(set) var statusMessage = L10n.ready
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isUploading = false

    private let captureService = ScreenCaptureService()
    private let textRecognitionService = TextRecognitionService()
    private let updateCheckService = UpdateCheckService()
    private let r2SettingsStore: CloudflareR2SettingsStore
    private var annotationUndoStack: [[CaptureAnnotation]] = []
    private var isApplyingAnnotationHistory = false
    private let maxUndoDepth = 60

    init() {
        self.r2SettingsStore = CloudflareR2SettingsStore()
    }

    init(r2SettingsStore: CloudflareR2SettingsStore) {
        self.r2SettingsStore = r2SettingsStore
    }

    var hasImage: Bool {
        document != nil
    }

    var canUndoAnnotation: Bool {
        !annotationUndoStack.isEmpty
    }

    var documentTitle: String {
        document?.displayTitle ?? L10n.appName
    }

    var imageDimensionsTitle: String {
        guard let document else {
            return L10n.noImage
        }
        return "\(Int(document.pixelSize.width)) x \(Int(document.pixelSize.height))"
    }

    var ocrLineCount: Int {
        ocrText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    var annotationCountTitle: String {
        switch annotations.count {
        case 0:
            return L10n.noMarkup
        case 1:
            return L10n.oneMarkup
        default:
            return L10n.markups(annotations.count)
        }
    }

    func captureRegion() {
        guard !isCapturing else { return }
        isCapturing = true
        statusMessage = L10n.selectRegionPrompt

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.captureService.captureInteractiveRegionFile() }
            DispatchQueue.main.async {
                self.isCapturing = false
                switch result {
                case .success(let url):
                    if self.loadImage(from: url, sourceURL: nil, status: L10n.capturedRegion) {
                        self.copyRenderedImage(successStatus: L10n.capturedRegionAndCopied)
                    }
                case .failure(let error):
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.title = L10n.openImageTitle
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        loadImage(from: url, sourceURL: url, status: L10n.opened(url.lastPathComponent))
    }

    @discardableResult
    func copyRenderedImage(successStatus: String = L10n.imageCopied) -> Bool {
        guard let document else {
            NSSound.beep()
            return false
        }
        let rendered = document.image.renderedWithCaptureLabAnnotations(annotations)
        NSPasteboard.general.clearContents()
        let didCopy = NSPasteboard.general.writeObjects([rendered])
        statusMessage = didCopy ? successStatus : L10n.imageCopyFailed
        if !didCopy {
            NSSound.beep()
        }
        return didCopy
    }

    func saveRenderedImage() {
        guard let document else {
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.title = L10n.saveCaptureTitle
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultSaveName(for: document)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard let data = document.image.captureLabPNGData(annotations: annotations) else {
            statusMessage = CaptureLabError.imageExportFailed.localizedDescription
            NSSound.beep()
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            statusMessage = L10n.saved(url.lastPathComponent)
        } catch {
            statusMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    func uploadRenderedImage(onSuccess: ((String) -> Void)? = nil) {
        guard !isUploading else {
            return
        }
        guard let document else {
            NSSound.beep()
            return
        }
        let settings: CloudflareR2Settings
        do {
            settings = try r2SettingsStore.requiredSettings()
        } catch {
            presentUploadFailure(error)
            return
        }
        guard let data = document.image.captureLabPNGData(annotations: annotations) else {
            presentUploadFailure(CloudflareR2Error.imageExportFailed)
            return
        }

        isUploading = true
        statusMessage = L10n.uploading

        let fileName = defaultUploadName(for: document)
        let service = CloudflareR2UploadService()
        Task {
            do {
                let result = try await service.upload(CloudflareR2UploadRequest(
                    settings: settings,
                    data: data,
                    fileName: fileName,
                    contentType: "image/png"
                ))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                statusMessage = L10n.uploadedURLCopied
                onSuccess?(result.url)
            } catch {
                presentUploadFailure(error)
            }
            isUploading = false
        }
    }

    func recognizeText() {
        guard let image = document?.image.captureLabCGImage() else {
            statusMessage = CaptureLabError.ocrImageUnavailable.localizedDescription
            NSSound.beep()
            return
        }

        isRecognizingText = true
        statusMessage = L10n.recognizingText

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.textRecognitionService.recognizeText(in: image) }
            DispatchQueue.main.async {
                self.isRecognizingText = false
                switch result {
                case .success(let ocr):
                    self.ocrText = ocr.text
                    self.statusMessage = ocr.lineCount == 0
                        ? L10n.noTextFound
                        : L10n.recognizedLines(ocr.lineCount)
                case .failure(let error):
                    self.statusMessage = error.localizedDescription
                    NSSound.beep()
                }
            }
        }
    }

    func copyOCRText() {
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = L10n.ocrTextCopied
    }

    func clearOCRText() {
        ocrText = ""
        statusMessage = L10n.ocrTextCleared
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        statusMessage = L10n.checkingForUpdates

        Task {
            do {
                let result = try await updateCheckService.checkForUpdates(currentVersion: Self.currentAppVersion)
                presentUpdateResult(result)
            } catch {
                presentUpdateFailure(error)
            }
            isCheckingForUpdates = false
        }
    }

    func addAnnotation(_ annotation: CaptureAnnotation) {
        let hasRect = annotation.normalizedRect.width > 0.006 && annotation.normalizedRect.height > 0.006
        let hasLine = annotation.normalizedPoints.count >= 2
        guard hasRect || hasLine else {
            return
        }
        annotations.append(annotation)
        statusMessage = L10n.annotationAdded(annotation.kind.displayTitle)
    }

    func undoAnnotation() {
        guard let previousAnnotations = annotationUndoStack.popLast() else {
            return
        }
        isApplyingAnnotationHistory = true
        annotations = previousAnnotations
        isApplyingAnnotationHistory = false
        statusMessage = L10n.markupUndone
    }

    func clearAnnotations() {
        annotations.removeAll()
        statusMessage = L10n.markupCleared
    }

    func clearDocument() {
        document = nil
        resetAnnotations()
        ocrText = ""
        statusMessage = L10n.ready
    }

    @discardableResult
    private func loadImage(from url: URL, sourceURL: URL?, status: String) -> Bool {
        guard let image = NSImage(contentsOf: url), image.isValid else {
            statusMessage = CaptureLabError.imageLoadFailed.localizedDescription
            NSSound.beep()
            return false
        }

        document = CaptureDocument(image: image, sourceURL: sourceURL, createdAt: Date())
        resetAnnotations()
        ocrText = ""
        statusMessage = status
        return true
    }

    private func defaultSaveName(for document: CaptureDocument) -> String {
        let baseName = document.sourceURL?.deletingPathExtension().lastPathComponent ?? L10n.appName
        return "\(baseName)-edited.png"
    }

    private func defaultUploadName(for document: CaptureDocument) -> String {
        if let sourceURL = document.sourceURL {
            return "\(sourceURL.deletingPathExtension().lastPathComponent)-edited.png"
        }
        return "capture-\(Self.uploadFileTimestampFormatter.string(from: document.createdAt)).png"
    }

    private func trackAnnotationChange(from oldValue: [CaptureAnnotation], to newValue: [CaptureAnnotation]) {
        guard !isApplyingAnnotationHistory,
              oldValue != newValue
        else {
            return
        }

        annotationUndoStack.append(oldValue)
        if annotationUndoStack.count > maxUndoDepth {
            annotationUndoStack.removeFirst(annotationUndoStack.count - maxUndoDepth)
        }
    }

    private func resetAnnotations() {
        isApplyingAnnotationHistory = true
        annotations.removeAll()
        isApplyingAnnotationHistory = false
        annotationUndoStack.removeAll()
    }

    private static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
    }

    private static let uploadFileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func presentUpdateResult(_ result: UpdateCheckResult) {
        switch result {
        case .updateAvailable(let currentVersion, let latestVersion, let releaseURL):
            statusMessage = L10n.updateAvailableTitle
            let alert = NSAlert()
            alert.messageText = L10n.updateAvailableTitle
            alert.informativeText = L10n.updateAvailableMessage(current: currentVersion, latest: latestVersion)
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.openReleasePage)
            alert.addButton(withTitle: L10n.later)

            if alert.captureLabRunModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releaseURL)
            }
        case .upToDate(let currentVersion, _):
            statusMessage = L10n.upToDateTitle
            let alert = NSAlert()
            alert.messageText = L10n.upToDateTitle
            alert.informativeText = L10n.upToDateMessage(current: currentVersion)
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.ok)
            _ = alert.captureLabRunModal()
        }
    }

    private func presentUpdateFailure(_ error: Error) {
        statusMessage = L10n.updateCheckFailedTitle
        let alert = NSAlert()
        alert.messageText = L10n.updateCheckFailedTitle
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.ok)
        _ = alert.captureLabRunModal()
    }

    private func presentUploadFailure(_ error: Error) {
        statusMessage = error.localizedDescription
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = L10n.uploadFailedTitle
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.ok)
        _ = alert.captureLabRunModal()
    }
}
