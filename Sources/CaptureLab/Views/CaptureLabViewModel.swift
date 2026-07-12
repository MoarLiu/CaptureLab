import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol CaptureWindowRestoring: AnyObject {
    func restore()
}

@MainActor
protocol CaptureWindowVisibilityCoordinating: AnyObject {
    func hideVisibleWindowsForCapture() -> any CaptureWindowRestoring
    func waitUntilWindowsAreHidden() async
}

@MainActor
final class SystemCaptureWindowVisibilityCoordinator: CaptureWindowVisibilityCoordinating {
    func hideVisibleWindowsForCapture() -> any CaptureWindowRestoring {
        let visibleWindows = NSApp.windows.filter(\.isVisible)
        let keyWindow = NSApp.keyWindow
        visibleWindows.forEach { $0.orderOut(nil) }
        return SystemCaptureWindowRestoration(windows: visibleWindows, keyWindow: keyWindow)
    }

    func waitUntilWindowsAreHidden() async {
        // AppKit sends orderOut to WindowServer asynchronously. Give it a render
        // turn before starting screencapture so CaptureLab cannot enter the frame.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
}

@MainActor
private final class SystemCaptureWindowRestoration: CaptureWindowRestoring {
    private let windows: [NSWindow]
    private weak var keyWindow: NSWindow?
    private var didRestore = false

    init(windows: [NSWindow], keyWindow: NSWindow?) {
        self.windows = windows
        self.keyWindow = keyWindow
    }

    func restore() {
        guard !didRestore else { return }
        didRestore = true

        windows.forEach { window in
            if !window.isVisible {
                window.orderFront(nil)
            }
        }
        if let keyWindow, !keyWindow.isMiniaturized {
            keyWindow.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class CaptureLabViewModel: ObservableObject {
    typealias CaptureOperation = @MainActor (CaptureMode) async throws -> URL
    typealias TextRecognitionOperation = @MainActor (CGImage) async throws -> OCRResult
    typealias UploadOperation = @MainActor (CloudflareR2UploadRequest) async throws -> CloudflareR2UploadResult
    typealias ImageRenderingOperation = @MainActor (NSImage, [CaptureAnnotation]) -> NSImage?
    typealias PNGDataRenderingOperation = @MainActor (NSImage, [CaptureAnnotation]) -> Data?
    typealias SaveDestinationOperation = @MainActor (_ suggestedFileName: String) -> URL?

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
    @Published private(set) var historyItems: [CaptureHistoryItem]

    private let updateCheckService = UpdateCheckService()
    private let updateInstallService = UpdateInstallService()
    private let r2SettingsStore: CloudflareR2SettingsStore
    private let historyStore: CaptureHistoryStore
    private let pasteboard: NSPasteboard
    private let windowVisibilityCoordinator: any CaptureWindowVisibilityCoordinating
    private let captureOperation: CaptureOperation
    private let textRecognitionOperation: TextRecognitionOperation
    private let uploadOperation: UploadOperation
    private let imageRenderingOperation: ImageRenderingOperation
    private let pngDataRenderingOperation: PNGDataRenderingOperation
    private let saveDestinationOperation: SaveDestinationOperation
    private var annotationUndoStack: [[CaptureAnnotation]] = []
    private var isApplyingAnnotationHistory = false
    private let maxUndoDepth = 60
    private var documentGeneration: UInt64 = 0
    private var ocrRequestID: UUID?
    private var ocrTask: Task<Void, Never>?
    private var uploadRequestID: UUID?
    private var uploadTask: Task<Void, Never>?

    init() {
        self.r2SettingsStore = CloudflareR2SettingsStore()
        self.historyStore = CaptureHistoryStore()
        self.pasteboard = .general
        self.windowVisibilityCoordinator = SystemCaptureWindowVisibilityCoordinator()
        self.captureOperation = Self.defaultCaptureOperation
        self.textRecognitionOperation = Self.defaultTextRecognitionOperation
        self.uploadOperation = Self.defaultUploadOperation
        self.imageRenderingOperation = Self.defaultImageRenderingOperation
        self.pngDataRenderingOperation = Self.defaultPNGDataRenderingOperation
        self.saveDestinationOperation = Self.defaultSaveDestinationOperation
        self.historyItems = historyStore.items
    }

    init(r2SettingsStore: CloudflareR2SettingsStore) {
        self.r2SettingsStore = r2SettingsStore
        self.historyStore = CaptureHistoryStore()
        self.pasteboard = .general
        self.windowVisibilityCoordinator = SystemCaptureWindowVisibilityCoordinator()
        self.captureOperation = Self.defaultCaptureOperation
        self.textRecognitionOperation = Self.defaultTextRecognitionOperation
        self.uploadOperation = Self.defaultUploadOperation
        self.imageRenderingOperation = Self.defaultImageRenderingOperation
        self.pngDataRenderingOperation = Self.defaultPNGDataRenderingOperation
        self.saveDestinationOperation = Self.defaultSaveDestinationOperation
        self.historyItems = historyStore.items
    }

    init(
        r2SettingsStore: CloudflareR2SettingsStore,
        historyStore: CaptureHistoryStore,
        pasteboard: NSPasteboard = .general,
        windowVisibilityCoordinator: (any CaptureWindowVisibilityCoordinating)? = nil,
        captureOperation: @escaping CaptureOperation = CaptureLabViewModel.defaultCaptureOperation,
        textRecognitionOperation: @escaping TextRecognitionOperation = CaptureLabViewModel.defaultTextRecognitionOperation,
        uploadOperation: @escaping UploadOperation = CaptureLabViewModel.defaultUploadOperation,
        imageRenderingOperation: @escaping ImageRenderingOperation = CaptureLabViewModel.defaultImageRenderingOperation,
        pngDataRenderingOperation: @escaping PNGDataRenderingOperation = CaptureLabViewModel.defaultPNGDataRenderingOperation,
        saveDestinationOperation: @escaping SaveDestinationOperation = CaptureLabViewModel.defaultSaveDestinationOperation
    ) {
        self.r2SettingsStore = r2SettingsStore
        self.historyStore = historyStore
        self.pasteboard = pasteboard
        self.windowVisibilityCoordinator = windowVisibilityCoordinator ?? SystemCaptureWindowVisibilityCoordinator()
        self.captureOperation = captureOperation
        self.textRecognitionOperation = textRecognitionOperation
        self.uploadOperation = uploadOperation
        self.imageRenderingOperation = imageRenderingOperation
        self.pngDataRenderingOperation = pngDataRenderingOperation
        self.saveDestinationOperation = saveDestinationOperation
        self.historyItems = historyStore.items
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
        capture(.region)
    }

    func capture(_ mode: CaptureMode, onSuccess: (() -> Void)? = nil) {
        guard !isCapturing else { return }
        isCapturing = true
        statusMessage = mode.promptTitle

        let restoration = windowVisibilityCoordinator.hideVisibleWindowsForCapture()
        let captureOperation = self.captureOperation
        let windowVisibilityCoordinator = self.windowVisibilityCoordinator
        Task { [weak self] in
            await windowVisibilityCoordinator.waitUntilWindowsAreHidden()

            let result: Result<URL, Error>
            do {
                result = .success(try await captureOperation(mode))
            } catch {
                result = .failure(error)
            }

            restoration.restore()
            defer {
                if case .success(let url) = result {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            guard let self else {
                return
            }

            self.isCapturing = false
            switch result {
            case .success(let url):
                if self.loadImage(from: url, sourceURL: nil, status: mode.completedTitle) {
                    let historyError = self.recordCurrentCaptureInHistory()
                    let didCopy = self.copyRenderedImage(successStatus: mode.completedAndCopiedTitle)
                    if didCopy, let historyError {
                        self.statusMessage = L10n.captureCopiedButHistorySaveFailed(historyError)
                    }
                    onSuccess?()
                }
            case .failure(let error):
                self.statusMessage = error.localizedDescription
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
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else {
            NSSound.beep()
            return false
        }
        guard let rendered = imageRenderingOperation(document.image, annotations) else {
            statusMessage = L10n.imageCopyFailed
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        let didCopy = pasteboard.writeObjects([rendered])
        statusMessage = didCopy ? successStatus : L10n.imageCopyFailed
        if !didCopy {
            NSSound.beep()
        }
        return didCopy
    }

    func saveRenderedImage() {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else {
            NSSound.beep()
            return
        }

        // Render before entering the modal run loop. Global hotkeys remain active
        // while NSSavePanel is open, so both the source image and annotations must
        // already be frozen into immutable bytes before another capture can replace
        // the current document.
        guard let data = pngDataRenderingOperation(document.image, annotations) else {
            statusMessage = CaptureLabError.imageExportFailed.localizedDescription
            NSSound.beep()
            return
        }
        guard let url = saveDestinationOperation(defaultSaveName(for: document)) else {
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
        CaptureEditingSession.commitPendingTextEdits()
        guard !isUploading else {
            return
        }
        guard let document else {
            NSSound.beep()
            return
        }
        guard let data = document.image.captureLabPNGData(annotations: annotations) else {
            presentUploadFailure(CloudflareR2Error.imageExportFailed)
            return
        }

        uploadPNGData(data, fileName: defaultUploadName(for: document), onSuccess: onSuccess)
    }

    func openHistoryItem(_ item: CaptureHistoryItem) {
        let url = historyStore.url(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = CaptureHistoryError.imageNotFound.localizedDescription
            NSSound.beep()
            return
        }
        loadImage(from: url, sourceURL: url, status: L10n.historyCaptureOpened)
    }

    func copyHistoryItem(_ item: CaptureHistoryItem) {
        let url = historyStore.url(for: item)
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              image.isValid
        else {
            statusMessage = CaptureHistoryError.imageNotFound.localizedDescription
            NSSound.beep()
            return
        }

        pasteboard.clearContents()
        let didCopy = pasteboard.writeObjects([image])
        statusMessage = didCopy ? L10n.imageCopied : L10n.imageCopyFailed
        if !didCopy {
            NSSound.beep()
        }
    }

    @discardableResult
    func finishEditing() -> Bool {
        CaptureEditingSession.commitPendingTextEdits()
        guard copyRenderedImage() else {
            return false
        }
        clearDocument()
        return true
    }

    func saveHistoryItem(_ item: CaptureHistoryItem) {
        let panel = NSSavePanel()
        panel.title = L10n.saveCaptureTitle
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = item.fileName

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try historyStore.data(for: item)
            try data.write(to: url, options: .atomic)
            statusMessage = L10n.saved(url.lastPathComponent)
        } catch {
            statusMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    func uploadHistoryItem(_ item: CaptureHistoryItem, onSuccess: ((String) -> Void)? = nil) {
        do {
            let data = try historyStore.data(for: item)
            uploadPNGData(data, fileName: item.fileName, onSuccess: onSuccess)
        } catch {
            presentUploadFailure(error)
        }
    }

    private func uploadPNGData(_ data: Data, fileName: String, onSuccess: ((String) -> Void)? = nil) {
        guard !isUploading else {
            return
        }
        guard !data.isEmpty else {
            presentUploadFailure(CaptureHistoryError.imageDataUnavailable)
            return
        }

        let settings: CloudflareR2Settings
        do {
            settings = try r2SettingsStore.requiredSettings()
        } catch {
            presentUploadFailure(error)
            return
        }

        isUploading = true
        statusMessage = L10n.uploading

        let requestID = UUID()
        uploadRequestID = requestID
        let uploadOperation = self.uploadOperation
        uploadTask = Task { [weak self] in
            do {
                let result = try await uploadOperation(CloudflareR2UploadRequest(
                    settings: settings,
                    data: data,
                    fileName: fileName,
                    contentType: "image/png"
                ))
                try Task.checkCancellation()
                guard let self, self.uploadRequestID == requestID else {
                    return
                }
                self.pasteboard.clearContents()
                self.pasteboard.setString(result.url, forType: .string)
                self.statusMessage = L10n.uploadedURLCopied
                onSuccess?(result.url)
            } catch {
                guard let self, self.uploadRequestID == requestID else {
                    return
                }
                if !(error is CancellationError) {
                    self.presentUploadFailure(error)
                }
            }

            guard let self, self.uploadRequestID == requestID else {
                return
            }
            self.uploadRequestID = nil
            self.uploadTask = nil
            self.isUploading = false
        }
    }

    func recognizeText() {
        guard let image = document?.image.captureLabCGImage() else {
            statusMessage = CaptureLabError.ocrImageUnavailable.localizedDescription
            NSSound.beep()
            return
        }

        cancelTextRecognition()
        let requestID = UUID()
        let generation = documentGeneration
        ocrRequestID = requestID
        isRecognizingText = true
        statusMessage = L10n.recognizingText

        let textRecognitionOperation = self.textRecognitionOperation
        ocrTask = Task { [weak self] in
            do {
                let ocr = try await textRecognitionOperation(image)
                try Task.checkCancellation()
                guard let self,
                      self.ocrRequestID == requestID,
                      self.documentGeneration == generation
                else {
                    return
                }
                self.ocrText = ocr.text
                self.statusMessage = ocr.lineCount == 0
                    ? L10n.noTextFound
                    : L10n.recognizedLines(ocr.lineCount)
            } catch {
                guard let self,
                      self.ocrRequestID == requestID,
                      self.documentGeneration == generation
                else {
                    return
                }
                if !(error is CancellationError) {
                    self.statusMessage = error.localizedDescription
                    NSSound.beep()
                }
            }

            guard let self, self.ocrRequestID == requestID else {
                return
            }
            self.ocrRequestID = nil
            self.ocrTask = nil
            self.isRecognizingText = false
        }
    }

    func copyOCRText() {
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = L10n.ocrTextCopied
    }

    func clearOCRText() {
        cancelTextRecognition()
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
                try await presentUpdateResult(result)
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
        CaptureEditingSession.commitPendingTextEdits()
        guard let previousAnnotations = annotationUndoStack.popLast() else {
            return
        }
        isApplyingAnnotationHistory = true
        annotations = previousAnnotations
        isApplyingAnnotationHistory = false
        statusMessage = L10n.markupUndone
    }

    func clearAnnotations() {
        CaptureEditingSession.commitPendingTextEdits()
        annotations.removeAll()
        statusMessage = L10n.markupCleared
    }

    func clearDocument() {
        CaptureEditingSession.commitPendingTextEdits()
        invalidateDocumentActivities()
        document = nil
        resetAnnotations()
        ocrText = ""
        statusMessage = L10n.ready
    }

    @discardableResult
    private func loadImage(from url: URL, sourceURL: URL?, status: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              image.isValid
        else {
            statusMessage = CaptureLabError.imageLoadFailed.localizedDescription
            NSSound.beep()
            return false
        }

        // Flush and tear down any field editor tied to the outgoing document
        // before resetting bindings. Otherwise a later export could let that
        // stale canvas publish its annotations into the replacement document.
        CaptureEditingSession.commitPendingTextEdits()
        invalidateDocumentActivities()
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

    private func recordCurrentCaptureInHistory() -> String? {
        guard let document,
              let data = document.image.captureLabPNGData()
        else {
            return CaptureHistoryError.imageDataUnavailable.localizedDescription
        }

        do {
            _ = try historyStore.record(
                data: data,
                pixelSize: document.pixelSize,
                createdAt: document.createdAt
            )
            historyItems = historyStore.items
            return nil
        } catch {
            return error.localizedDescription
        }
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

    private func invalidateDocumentActivities() {
        documentGeneration &+= 1
        cancelTextRecognition()
        cancelUpload()
    }

    private func cancelTextRecognition() {
        ocrRequestID = nil
        ocrTask?.cancel()
        ocrTask = nil
        isRecognizingText = false
    }

    private func cancelUpload() {
        uploadRequestID = nil
        uploadTask?.cancel()
        uploadTask = nil
        isUploading = false
    }

    static func defaultCaptureOperation(_ mode: CaptureMode) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try ScreenCaptureService().captureFile(mode: mode)
        }.value
    }

    static func defaultTextRecognitionOperation(_ image: CGImage) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            try TextRecognitionService().recognizeText(in: image)
        }.value
    }

    static func defaultUploadOperation(_ request: CloudflareR2UploadRequest) async throws -> CloudflareR2UploadResult {
        try await CloudflareR2UploadService().upload(request)
    }

    static func defaultImageRenderingOperation(
        _ image: NSImage,
        _ annotations: [CaptureAnnotation]
    ) -> NSImage? {
        image.renderedWithCaptureLabAnnotations(annotations)
    }

    static func defaultPNGDataRenderingOperation(
        _ image: NSImage,
        _ annotations: [CaptureAnnotation]
    ) -> Data? {
        image.captureLabPNGData(annotations: annotations)
    }

    static func defaultSaveDestinationOperation(suggestedFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.saveCaptureTitle
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFileName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.2"
    }

    private static let uploadFileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func presentUpdateResult(_ result: UpdateCheckResult) async throws {
        switch result {
        case .updateAvailable(let currentVersion, let latestVersion, let package):
            statusMessage = L10n.updateAvailableTitle
            let alert = NSAlert()
            alert.messageText = L10n.updateAvailableTitle
            alert.informativeText = L10n.updateAvailableMessage(current: currentVersion, latest: latestVersion)
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.installUpdate)
            alert.addButton(withTitle: L10n.later)

            if alert.captureLabRunModal() == .alertFirstButtonReturn {
                statusMessage = L10n.downloadingUpdate(latestVersion)
                let dmgURL = try await updateCheckService.downloadUpdate(package, latestVersion: latestVersion)
                statusMessage = L10n.installingUpdate
                try updateInstallService.installAndRelaunch(
                    dmgURL: dmgURL,
                    expectedVersion: latestVersion,
                    expectedArchitecture: package.architecture
                )
                NSApp.terminate(nil)
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
