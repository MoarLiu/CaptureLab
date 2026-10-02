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
    typealias PinOperation = @MainActor (NSImage, String) -> Void
    typealias FailurePresentationOperation = @MainActor (_ title: String, _ message: String) -> Void

    @Published private(set) var document: CaptureDocument?
    @Published var annotations: [CaptureAnnotation] = [] {
        didSet {
            trackAnnotationChange(from: oldValue, to: annotations)
            if let id = selectedAnnotationID, !annotations.contains(where: { $0.id == id }) {
                selectedAnnotationID = nil
            }
        }
    }
    @Published var selectedTool: CaptureTool = .select {
        didSet {
            if selectedTool != .crop { cropSelection = nil }
            if let annotation = annotations.first(where: { $0.id == selectedAnnotationID }),
               selectedTool != .select, selectedTool.annotationKind != annotation.kind {
                selectedAnnotationID = nil
            }
        }
    }
    @Published var annotationAppearance: CaptureAnnotationAppearance = .editorDefault {
        didSet { applySelectedAnnotationAppearance() }
    }
    @Published private(set) var selectedAnnotationID: UUID?
    @Published var cropPreset: CaptureCropPreset = .free
    @Published var cropSelection: CGRect?
    @Published private(set) var historyRevision = UUID()
    @Published var ocrText = ""
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecognizingText = false
    @Published private(set) var statusMessage = L10n.ready
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isUploading = false
    @Published private(set) var historyItems: [CaptureHistoryItem] {
        didSet { historyRevision = UUID() }
    }
    @Published var finishEditingError: String?

    private let updateCheckService = UpdateCheckService()
    private let updateInstallService = UpdateInstallService()
    private let r2SettingsStore: CloudflareR2SettingsStore
    let historyStore: CaptureHistoryStore
    let workflowSettings: CaptureWorkflowSettings
    let overlayController = CaptureQuickAccessController()
    @Published private(set) var latestCapture: CaptureImageSnapshot?
    private var importRequestID = UUID()
    private var pendingSaveSnapshot: (id: UUID, annotations: [CaptureAnnotation], data: Data)?
    var presentEditor: (() -> Void)?
    var presentRecognition: (() -> Void)?
    var presentCaptureLauncher: (() -> Void)?
    lazy var directRecognition = DirectRecognitionController(pasteboard: pasteboard, text: textRecognitionOperation)

    func performCaptureAction(_ action: CaptureAction) {
        switch action {
        case .launcher: presentCaptureLauncher?()
        case .text: capture(.region, recognition: .text)
        case .qrCode: capture(.region, recognition: .qrCode)
        default: if let mode = action.mode { capture(mode) }
        }
    }
    private let pasteboard: NSPasteboard
    private let windowVisibilityCoordinator: any CaptureWindowVisibilityCoordinating
    private let captureOperation: CaptureOperation
    private let textRecognitionOperation: TextRecognitionOperation
    private let uploadOperation: UploadOperation
    private let imageRenderingOperation: ImageRenderingOperation
    private let pngDataRenderingOperation: PNGDataRenderingOperation
    private let saveDestinationOperation: SaveDestinationOperation
    private let failurePresentationOperation: FailurePresentationOperation
    private struct EditSnapshot {
        var document: CaptureDocument?
        var annotations: [CaptureAnnotation]
    }
    @Published private var annotationUndoStack: [EditSnapshot] = []
    @Published private var annotationRedoStack: [EditSnapshot] = []
    private let pinOperation: PinOperation
    private var isSynchronizingAppearance = false
    private var isApplyingAnnotationHistory = false
    private let maxUndoDepth = 60
    private var documentGeneration: UInt64 = 0
    private var ocrRequestID: UUID?
    private var ocrTask: Task<Void, Never>?
    private var uploadRequestID: UUID?
    private var uploadTask: Task<Void, Never>?
    private var currentHistoryItem: CaptureHistoryItem?

    init() {
        self.r2SettingsStore = CloudflareR2SettingsStore()
        self.historyStore = CaptureHistoryStore()
        self.workflowSettings = CaptureWorkflowSettings()
        self.pasteboard = .general
        self.windowVisibilityCoordinator = SystemCaptureWindowVisibilityCoordinator()
        self.captureOperation = Self.defaultCaptureOperation
        self.textRecognitionOperation = Self.defaultTextRecognitionOperation
        self.uploadOperation = Self.defaultUploadOperation
        self.imageRenderingOperation = Self.defaultImageRenderingOperation
        self.pngDataRenderingOperation = Self.defaultPNGDataRenderingOperation
        self.saveDestinationOperation = Self.defaultSaveDestinationOperation
        self.failurePresentationOperation = Self.defaultFailurePresentationOperation
        self.pinOperation = Self.defaultPinOperation
        self.historyItems = historyStore.items
        reportHistoryLoadFailureIfNeeded()
    }

    init(r2SettingsStore: CloudflareR2SettingsStore) {
        self.r2SettingsStore = r2SettingsStore
        self.historyStore = CaptureHistoryStore()
        self.workflowSettings = CaptureWorkflowSettings()
        self.pasteboard = .general
        self.windowVisibilityCoordinator = SystemCaptureWindowVisibilityCoordinator()
        self.captureOperation = Self.defaultCaptureOperation
        self.textRecognitionOperation = Self.defaultTextRecognitionOperation
        self.uploadOperation = Self.defaultUploadOperation
        self.imageRenderingOperation = Self.defaultImageRenderingOperation
        self.pngDataRenderingOperation = Self.defaultPNGDataRenderingOperation
        self.saveDestinationOperation = Self.defaultSaveDestinationOperation
        self.failurePresentationOperation = Self.defaultFailurePresentationOperation
        self.pinOperation = Self.defaultPinOperation
        self.historyItems = historyStore.items
        reportHistoryLoadFailureIfNeeded()
    }

    init(
        r2SettingsStore: CloudflareR2SettingsStore,
        historyStore: CaptureHistoryStore,
        failurePresentationOperation: @escaping FailurePresentationOperation = CaptureLabViewModel.defaultFailurePresentationOperation,
        pasteboard: NSPasteboard = .general,
        windowVisibilityCoordinator: (any CaptureWindowVisibilityCoordinating)? = nil,
        captureOperation: @escaping CaptureOperation = CaptureLabViewModel.defaultCaptureOperation,
        textRecognitionOperation: @escaping TextRecognitionOperation = CaptureLabViewModel.defaultTextRecognitionOperation,
        uploadOperation: @escaping UploadOperation = CaptureLabViewModel.defaultUploadOperation,
        imageRenderingOperation: @escaping ImageRenderingOperation = CaptureLabViewModel.defaultImageRenderingOperation,
        pngDataRenderingOperation: @escaping PNGDataRenderingOperation = CaptureLabViewModel.defaultPNGDataRenderingOperation,
        saveDestinationOperation: @escaping SaveDestinationOperation = CaptureLabViewModel.defaultSaveDestinationOperation,
        pinOperation: @escaping PinOperation = CaptureLabViewModel.defaultPinOperation,
        workflowSettings: CaptureWorkflowSettings? = nil
    ) {
        self.r2SettingsStore = r2SettingsStore
        self.historyStore = historyStore
        self.workflowSettings = workflowSettings ?? CaptureWorkflowSettings(defaults: nil)
        self.pasteboard = pasteboard
        self.windowVisibilityCoordinator = windowVisibilityCoordinator ?? SystemCaptureWindowVisibilityCoordinator()
        self.captureOperation = captureOperation
        self.textRecognitionOperation = textRecognitionOperation
        self.uploadOperation = uploadOperation
        self.imageRenderingOperation = imageRenderingOperation
        self.pngDataRenderingOperation = pngDataRenderingOperation
        self.saveDestinationOperation = saveDestinationOperation
        self.failurePresentationOperation = failurePresentationOperation
        self.pinOperation = pinOperation
        self.historyItems = historyStore.items
        reportHistoryLoadFailureIfNeeded()
    }

    var hasImage: Bool {
        document != nil
    }

    var canUndoAnnotation: Bool {
        !annotationUndoStack.isEmpty
    }

    var canRedoAnnotation: Bool { !annotationRedoStack.isEmpty }

    var canApplyCrop: Bool {
        guard let document, let cropSelection,
              let rect = CaptureImageCrop.pixelRect(cropSelection, pixelSize: document.canvasSize) else { return false }
        return rect.width >= 1 && rect.height >= 1
    }

    func selectAnnotation(_ id: UUID?) {
        guard let id, let annotation = annotations.first(where: { $0.id == id }) else {
            if selectedAnnotationID != nil { selectedAnnotationID = nil }
            return
        }
        selectedAnnotationID = id
        isSynchronizingAppearance = true
        annotationAppearance = annotation.appearance
        isSynchronizingAppearance = false
    }

    private func applySelectedAnnotationAppearance() {
        guard !isSynchronizingAppearance else { return }
        CaptureEditingSession.commitPendingTextEdits()
        guard let selectedAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }) else { return }
        var updated = annotations
        let fontChanged = updated[index].appearance.fontSize != annotationAppearance.fontSize
        updated[index].appearance = annotationAppearance
        if fontChanged, let document {
            updated[index] = updated[index].fittingFontBounds(in: document.sourcePixelSize)
        }
        annotations = updated
    }

    @discardableResult
    func applyCrop() -> Bool {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document, let cropSelection, canApplyCrop else { return false }
        guard let cropped = document.cropping(to: cropSelection),
              renderImage(document: cropped) != nil else {
            reportFailure(L10n.imageExportFailed, title: L10n.cropFailedTitle)
            return false
        }
        applyDocumentEdit(cropped)
        statusMessage = L10n.imageCropped
        return true
    }

    private func applyDocumentEdit(_ updated: CaptureDocument) {
        appendUndo(EditSnapshot(document: document, annotations: annotations))
        annotationRedoStack.removeAll()
        invalidateDocumentActivities()
        document = updated
        selectedAnnotationID = nil
        cropSelection = nil
        selectedTool = .select
        ocrText = ""
    }

    func adjustImage(_ adjustment: CaptureDocument.Adjustment) {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else { return }
        applyDocumentEdit(document.adjusting(adjustment))
        statusMessage = L10n.text(en: "Image adjusted", zh: "图片已调整")
    }

    @discardableResult
    func resizeOutput(to size: CGSize) -> Bool {
        CaptureEditingSession.commitPendingTextEdits()
        guard var updated = document, CaptureDocumentGeometry.validSize(size) else {
            reportFailure(L10n.text(en: "Enter whole pixel dimensions from 1 to 32768, up to 100 megapixels.",
                                    zh: "请输入 1 至 32768 的整数像素尺寸，总像素不超过一亿。"), title: L10n.imageExportFailed)
            return false
        }
        guard updated.pixelSize != size else { return true }
        updated.id = UUID()
        updated.geometry.outputSize = size
        applyDocumentEdit(updated)
        statusMessage = L10n.text(en: "Output size updated", zh: "输出尺寸已更新")
        return true
    }

    private func renderImage(document: CaptureDocument) -> NSImage? {
        guard let rendered = imageRenderingOperation(document.image, annotations) else { return nil }
        return document.applyingGeometry(to: rendered)
    }

    private func renderPNG(document: CaptureDocument) -> Data? {
        guard let data = pngDataRenderingOperation(document.image, annotations) else { return nil }
        guard document.geometry != CaptureDocumentGeometry() else { return data }
        guard let rendered = NSImage(data: data) else { return nil }
        return document.applyingGeometry(to: rendered)?.captureLabPNGData()
    }

    func constrainCropSelection() {
        guard let document, let selection = cropSelection,
              let ratio = cropPreset.ratio(in: document.canvasSize) else { return }
        cropSelection = CaptureCropGeometry.selection(anchor: selection.origin,
            current: CGPoint(x: selection.maxX, y: selection.maxY), size: document.canvasSize, ratio: ratio)
    }

    func cancelCrop() {
        cropSelection = nil
        selectedTool = .select
    }

    func historyURL(for item: CaptureHistoryItem) -> URL { historyStore.url(for: item) }

    func refreshHistory() {
        do {
            try historyStore.refresh()
            historyItems = historyStore.items
        } catch {
            reportFailure(error.localizedDescription, title: L10n.historyLoadFailedTitle)
        }
    }

    func deleteHistoryItem(_ item: CaptureHistoryItem) {
        do {
            try historyStore.remove(item)
            historyItems = historyStore.items
            if currentHistoryItem?.id == item.id { currentHistoryItem = nil }
        } catch {
            historyItems = historyStore.items
            reportFailure(error.localizedDescription, title: L10n.historyDeleteFailedTitle)
        }
    }

    func pinCurrentCapture() {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else { return }
        guard let rendered = renderImage(document: document) else {
            reportFailure(L10n.imageExportFailed, title: L10n.pinFailedTitle)
            return
        }
        pinOperation(rendered, document.displayTitle)
    }

    func pinHistoryItem(_ item: CaptureHistoryItem) {
        do {
            let snapshot = try historyImageSnapshot(for: item)
            guard let image = NSImage(data: snapshot.data), image.isValid else { throw CaptureLabError.imageLoadFailed }
            pinOperation(image, snapshot.item.displayTitle)
        } catch {
            reportFailure(error.localizedDescription, title: L10n.pinFailedTitle)
        }
    }

    static func defaultPinOperation(_ image: NSImage, title: String) {
        CapturePinController.shared.pin(image: image, title: title)
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

    func capture(_ mode: CaptureMode, recognition: DirectRecognitionController.Kind? = nil, onSuccess: (() -> Void)? = nil) {
        guard !isCapturing else { return }
        directRecognition.cancel()
        if recognition != nil { cancelTextRecognition(); cancelUpload() }
        isCapturing = true
        statusMessage = mode.promptTitle

        overlayController.isCapturing = true
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
            self.overlayController.isCapturing = false
            switch result {
            case .success(let url):
                if let recognition {
                    if let image = NSImage(contentsOf: url)?.captureLabCGImage() {
                        self.directRecognition.start(image: image, kind: recognition)
                        self.presentRecognition?()
                    } else { self.reportFailure(L10n.imageLoadFailed, title: L10n.ocrFailedTitle) }
                } else {
                    self.receiveCapture(url: url, mode: mode, showEditor: onSuccess ?? self.presentEditor)
                }
            case .failure(let error):
                if error is CancellationError {
                    self.statusMessage = L10n.captureCancelled
                } else if let captureError = error as? CaptureLabError, case .captureCancelled = captureError {
                    self.statusMessage = error.localizedDescription
                } else {
                    self.reportFailure(error.localizedDescription, title: L10n.captureFailedTitle)
                }
            }
        }
    }

    private func receiveCapture(url: URL, mode: CaptureMode, showEditor: (() -> Void)?) {
        let options = workflowSettings.options.validated
        if options.afterCapture == .editor {
            guard loadImage(from: url, sourceURL: nil, status: mode.completedTitle) else { return }
            let historyError = recordCurrentCaptureInHistory()
            let didCopy = copyRenderedImage(successStatus: mode.completedAndCopiedTitle)
            if didCopy, let historyError {
                reportFailure(L10n.captureCopiedButHistorySaveFailed(historyError), title: L10n.historySaveFailedTitle)
            }
            if let document, let data = document.image.captureLabPNGData() {
                latestCapture = CaptureImageSnapshot(data: data, historyItem: currentHistoryItem)
            }
            showEditor?()
            return
        }
        do {
            let data = try CaptureImageImport.data(from: url)
            var item: CaptureHistoryItem?
            var historyFailure: Error?
            let image = NSImage(data: data)!
            do {
                item = try historyStore.record(data: data, pixelSize: image.captureLabPixelSize)
                historyItems = historyStore.items
            } catch { historyFailure = error }
            let snapshot = CaptureImageSnapshot(data: data, historyItem: item)
            latestCapture = snapshot
            _ = copyRenderedImage(image, successStatus: mode.completedAndCopiedTitle)
            if let historyFailure {
                reportFailure(L10n.captureCopiedButHistorySaveFailed(historyFailure.localizedDescription), title: L10n.historySaveFailedTitle)
            }
            if options.afterCapture == .overlay {
                let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                overlayController.show(.init(snapshot: snapshot,
                    screenNumber: screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                    edit: { [weak self] in
                        guard let self, self.openSnapshot(snapshot) else { return false }
                        showEditor?()
                        return true
                    },
                    copy: { [weak self] in self?.copySnapshot(snapshot) },
                    save: { [weak self] in self?.saveSnapshot(snapshot) },
                    pin: { [weak self] in self?.pinSnapshot(snapshot) },
                    upload: { [weak self] in self?.uploadSnapshot(snapshot) }), options: options)
            }
        } catch { reportFailure(error.localizedDescription, title: L10n.imageOpenFailedTitle) }
    }

    /// Persist editable recovery state before replacing or closing a document.
    /// Failure leaves both the active document and its undo history available.
    func preserveDocumentBeforeReplacement() -> Bool {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else { return true }
        let frozen = pendingSaveSnapshot.flatMap { $0.id == document.id && $0.annotations == annotations ? $0.data : nil }
        guard let data = frozen ?? renderPNG(document: document) else {
            reportFailure(CaptureLabError.imageExportFailed.localizedDescription, title: L10n.historySaveFailedTitle)
            return false
        }
        do {
            currentHistoryItem = try persistEditableDocument(document, preview: data)
            historyItems = historyStore.items
            return true
        } catch {
            reportFailure(error.localizedDescription, title: L10n.historySaveFailedTitle)
            return false
        }
    }

    @discardableResult
    func openSnapshot(_ snapshot: CaptureImageSnapshot) -> Bool {
        guard !isCapturing, loadImage(data: snapshot.data, sourceURL: nil, status: L10n.historyCaptureOpened) else { return false }
        // An overlay retains old pixels even if another process edits its history
        // entry. Never overwrite that newer revision when editing this snapshot.
        if let item = snapshot.historyItem,
           let durable = try? historyStore.imageSnapshot(for: item), durable.data == snapshot.data,
           durable.item.fileName == item.fileName, durable.item.projectFileName == nil {
            currentHistoryItem = durable.item
        }
        return true
    }

    func renderedSnapshot() -> CaptureImageSnapshot? {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else { return nil }
        guard let data = renderPNG(document: document) else {
            reportFailure(CaptureLabError.imageExportFailed.localizedDescription, title: L10n.imageSaveFailedTitle)
            return nil
        }
        return CaptureImageSnapshot(data: data, fileName: defaultSaveName(for: document))
    }

    func snapshot(for item: CaptureHistoryItem) -> CaptureImageSnapshot? {
        do {
            let value = try historyImageSnapshot(for: item)
            return CaptureImageSnapshot(data: value.data, fileName: value.item.fileName, historyItem: value.item)
        } catch {
            reportFailure(error.localizedDescription, title: L10n.imageOpenFailedTitle)
            return nil
        }
    }

    func copySnapshot(_ snapshot: CaptureImageSnapshot) {
        guard let image = snapshot.image else { return }
        _ = copyRenderedImage(image, successStatus: L10n.imageCopied)
    }
    func saveSnapshot(_ snapshot: CaptureImageSnapshot) {
        guard let url = saveDestinationOperation(snapshot.fileName) else { return }
        do {
            try snapshot.data.write(to: url, options: .atomic)
            statusMessage = L10n.saved(url.lastPathComponent)
        } catch { reportFailure(error.localizedDescription, title: L10n.imageSaveFailedTitle) }
    }
    func pinSnapshot(_ snapshot: CaptureImageSnapshot) {
        guard let image = snapshot.image else { return }
        pinOperation(image, snapshot.fileName)
    }
    func uploadSnapshot(_ snapshot: CaptureImageSnapshot) {
        uploadPNGData(snapshot.data, fileName: snapshot.fileName)
    }

    func pasteImage() {
        guard !isCapturing else { return }
        do { _ = importImageData(try CaptureImageImport.data(from: pasteboard)) }
        catch { reportFailure(error.localizedDescription, title: L10n.imageOpenFailedTitle) }
    }

    @discardableResult
    func importImageData(_ data: Data) -> Bool {
        guard !isCapturing else { return false }
        return loadImage(data: data, sourceURL: nil, status: L10n.text(en: "Image imported", zh: "图片已导入"))
    }

    func importDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard !isCapturing, let provider = providers.first else { return false }
        let type = provider.registeredTypeIdentifiers.first { $0 == UTType.fileURL.identifier }
            ?? provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        guard let type else { return false }
        let token = UUID()
        importRequestID = token
        let generation = documentGeneration
        provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.importRequestID == token, self.documentGeneration == generation else { return }
                do {
                    guard let data else { throw CaptureLabError.captureFailed(failure ?? CaptureLabError.imageLoadFailed.localizedDescription) }
                    if type == UTType.fileURL.identifier {
                        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                            throw CaptureLabError.imageLoadFailed
                        }
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if url.pathExtension.lowercased() == "capturelab" { _ = self.openProject(at: url) }
                        else { _ = self.importImageData(try CaptureImageImport.data(from: url)) }
                    } else { _ = self.importImageData(data) }
                } catch { self.reportFailure(error.localizedDescription, title: L10n.imageOpenFailedTitle) }
            }
        }
        return true
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.title = L10n.openImageTitle
        panel.allowedContentTypes = [.image, .captureLabProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        if url.pathExtension.lowercased() == "capturelab" { _ = openProject(at: url) }
        else { loadImage(from: url, sourceURL: url, status: L10n.opened(url.lastPathComponent)) }
    }

    @discardableResult
    func copyRenderedImage(successStatus: String = L10n.imageCopied) -> Bool {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else {
            NSSound.beep()
            return false
        }
        guard let rendered = renderImage(document: document) else {
            reportFailure(L10n.imageCopyFailed, title: L10n.imageCopyFailedTitle)
            return false
        }
        return copyRenderedImage(rendered, successStatus: successStatus)
    }

    private func copyRenderedImage(_ rendered: NSImage, successStatus: String, reportsFailure: Bool = true) -> Bool {
        pasteboard.clearContents()
        let didCopy = pasteboard.writeObjects([rendered])
        statusMessage = didCopy ? successStatus : L10n.imageCopyFailed
        if !didCopy {
            if reportsFailure {
                reportFailure(L10n.imageCopyFailed, title: L10n.imageCopyFailedTitle)
            } else {
                NSSound.beep()
            }
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
        guard let data = renderPNG(document: document) else {
            reportFailure(CaptureLabError.imageExportFailed.localizedDescription, title: L10n.imageSaveFailedTitle)
            return
        }
        let previousSnapshot = pendingSaveSnapshot
        pendingSaveSnapshot = (document.id, annotations, data)
        defer { pendingSaveSnapshot = previousSnapshot }
        guard let url = saveDestinationOperation(defaultSaveName(for: document)) else {
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            statusMessage = L10n.saved(url.lastPathComponent)
        } catch {
            reportFailure(error.localizedDescription, title: L10n.imageSaveFailedTitle)
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
        guard let data = renderPNG(document: document) else {
            presentUploadFailure(CloudflareR2Error.imageExportFailed)
            return
        }

        uploadPNGData(data, fileName: defaultUploadName(for: document), onSuccess: onSuccess)
    }

    func openHistoryItem(_ item: CaptureHistoryItem) {
        guard !isCapturing else { return }
        do {
            let isCurrent = currentHistoryItem?.id == item.id
            if isCurrent, !preserveDocumentBeforeReplacement() { return }
            let snapshot = try historyStore.editableSnapshot(for: currentHistoryItem.flatMap { isCurrent ? $0 : nil } ?? item)
            if let data = snapshot.project {
                let state = try CaptureProjectStore.decode(data, sourceURL: historyStore.url(for: snapshot.item))
                guard isCurrent || preserveDocumentBeforeReplacement() else { return }
                installProject(state, historyItem: snapshot.item)
            } else if loadImage(data: snapshot.preview, sourceURL: historyStore.url(for: snapshot.item), status: L10n.historyCaptureOpened, preserveExisting: !isCurrent) {
                currentHistoryItem = snapshot.item
            }
            historyItems = historyStore.items
        } catch { reportFailure(error.localizedDescription, title: L10n.imageOpenFailedTitle) }
    }

    private func persistEditableDocument(_ document: CaptureDocument, preview: Data) throws -> CaptureHistoryItem {
        let project = try CaptureProjectStore.encode(document: document, annotations: annotations)
        return try historyStore.saveEditable(preview: preview, project: project, for: currentHistoryItem,
                                             pixelSize: document.pixelSize, createdAt: document.createdAt)
    }

    func openProject() {
        guard !isCapturing else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text(en: "Open Editable Project", zh: "打开可编辑项目")
        panel.allowedContentTypes = [.captureLabProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = openProject(at: url)
    }

    @discardableResult
    func openProject(at url: URL) -> Bool {
        guard !isCapturing else { return false }
        do {
            let state = try CaptureProjectStore.read(url)
            guard preserveDocumentBeforeReplacement() else { return false }
            installProject(state, historyItem: nil)
            return true
        } catch {
            reportFailure(error.localizedDescription, title: L10n.imageOpenFailedTitle)
            return false
        }
    }

    private func installProject(_ state: CaptureProjectStore.State, historyItem: CaptureHistoryItem?) {
        importRequestID = UUID()
        invalidateDocumentActivities()
        resetAnnotations()
        document = state.document
        isApplyingAnnotationHistory = true
        annotations = state.annotations
        isApplyingAnnotationHistory = false
        currentHistoryItem = historyItem
        ocrText = ""
        finishEditingError = nil
        statusMessage = L10n.text(en: "Editable project opened", zh: "已打开可编辑项目")
    }

    func saveProject() {
        CaptureEditingSession.commitPendingTextEdits()
        guard let document else { return }
        do {
            // Freeze before the modal panel, just like ordinary image export.
            let data = try CaptureProjectStore.encode(document: document, annotations: annotations)
            let panel = NSSavePanel()
            panel.title = L10n.text(en: "Save Editable Project", zh: "保存可编辑项目")
            panel.message = L10n.text(en: "Contains the original image and editable annotations. Use Export Image when sharing a redacted image.",
                                      zh: "项目包含原图和可编辑标注。分享已遮挡内容时，请使用“保存图片”。")
            panel.allowedContentTypes = [.captureLabProject]
            panel.nameFieldStringValue = "CaptureLab.capturelab"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try CaptureProjectStore.write(data, to: url)
            statusMessage = L10n.saved(url.lastPathComponent)
        } catch { reportFailure(error.localizedDescription, title: L10n.imageSaveFailedTitle) }
    }

    func copyHistoryItem(_ item: CaptureHistoryItem) {
        do {
            let snapshot = try historyImageSnapshot(for: item)
            guard let image = NSImage(data: snapshot.data), image.isValid else {
                throw CaptureLabError.imageLoadFailed
            }
            _ = copyRenderedImage(image, successStatus: L10n.imageCopied)
        } catch {
            reportFailure(error.localizedDescription, title: L10n.imageCopyFailedTitle)
        }
    }

    @discardableResult
    func finishEditing() -> Bool {
        CaptureEditingSession.commitPendingTextEdits()
        finishEditingError = nil
        guard let document else {
            NSSound.beep()
            return false
        }
        // Freeze one rendered image for history and the clipboard. Do not clear
        // the editor until the durable history entry contains these same pixels.
        guard let rendered = renderImage(document: document),
              let data = rendered.captureLabPNGData() else {
            statusMessage = CaptureLabError.imageExportFailed.localizedDescription
            finishEditingError = statusMessage
            NSSound.beep()
            return false
        }

        do {
            currentHistoryItem = try persistEditableDocument(document, preview: data)
            historyItems = historyStore.items
        } catch {
            historyItems = historyStore.items
            statusMessage = error.localizedDescription
            finishEditingError = statusMessage
            NSSound.beep()
            return false
        }

        guard copyRenderedImage(rendered, successStatus: L10n.imageCopied, reportsFailure: false) else {
            finishEditingError = statusMessage
            return false
        }
        clearDocument()
        return true
    }

    func saveHistoryItem(_ item: CaptureHistoryItem) {
        do {
            let snapshot = try historyImageSnapshot(for: item)
            guard let url = saveDestinationOperation(snapshot.item.fileName) else { return }
            try snapshot.data.write(to: url, options: .atomic)
            statusMessage = L10n.saved(url.lastPathComponent)
        } catch {
            reportFailure(error.localizedDescription, title: L10n.imageSaveFailedTitle)
        }
    }

    func uploadHistoryItem(_ item: CaptureHistoryItem, onSuccess: ((String) -> Void)? = nil) {
        do {
            let snapshot = try historyImageSnapshot(for: item)
            uploadPNGData(snapshot.data, fileName: snapshot.item.fileName, onSuccess: onSuccess)
        } catch {
            presentUploadFailure(error)
        }
    }

    private func historyImageSnapshot(for item: CaptureHistoryItem) throws -> CaptureHistoryStore.ImageSnapshot {
        defer { historyItems = historyStore.items }
        return try historyStore.imageSnapshot(for: item)
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
        directRecognition.cancel()
        guard let document, let image = document.applyingGeometry(to: document.image)?.captureLabCGImage() else {
            reportFailure(CaptureLabError.ocrImageUnavailable.localizedDescription, title: L10n.ocrFailedTitle)
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
                    self.reportFailure(error.localizedDescription, title: L10n.ocrFailedTitle)
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
        guard let snapshot = annotationUndoStack.popLast() else { return }
        annotationRedoStack.append(EditSnapshot(document: document, annotations: annotations))
        restore(snapshot)
        statusMessage = L10n.editUndone
    }

    func redoAnnotation() {
        CaptureEditingSession.commitPendingTextEdits()
        guard let snapshot = annotationRedoStack.popLast() else { return }
        appendUndo(EditSnapshot(document: document, annotations: annotations))
        restore(snapshot)
        statusMessage = L10n.editRedone
    }

    private func restore(_ snapshot: EditSnapshot) {
        // OCR reads the source image, and uploads already own their rendered
        // bytes. Annotation-only history changes do not invalidate either.
        // Cropping creates a new document ID, including when undoing a crop.
        let sourceChanged = document?.id != snapshot.document?.id
        if sourceChanged {
            invalidateDocumentActivities()
        }
        isApplyingAnnotationHistory = true
        document = snapshot.document
        annotations = snapshot.annotations
        isApplyingAnnotationHistory = false
        selectedAnnotationID = nil
        cropSelection = nil
        selectedTool = .select
        if sourceChanged {
            ocrText = ""
        }
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
        currentHistoryItem = nil
        finishEditingError = nil
        resetAnnotations()
        ocrText = ""
        statusMessage = L10n.ready
    }

    @discardableResult
    private func loadImage(from url: URL, sourceURL: URL?, status: String) -> Bool {
        guard url.isFileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= CaptureImageImport.maximumBytes,
              let data = try? Data(contentsOf: url) else {
            reportFailure(CaptureLabError.imageLoadFailed.localizedDescription, title: L10n.imageOpenFailedTitle)
            return false
        }
        return loadImage(data: data, sourceURL: sourceURL, status: status)
    }

    @discardableResult
    private func loadImage(data: Data, sourceURL: URL?, status: String, preserveExisting: Bool = true) -> Bool {
        guard let png = try? CaptureImageImport.pngData(from: data),
              let image = NSImage(data: png), image.isValid else {
            reportFailure(CaptureLabError.imageLoadFailed.localizedDescription, title: L10n.imageOpenFailedTitle)
            return false
        }

        // Flush and tear down any field editor tied to the outgoing document
        // before resetting bindings. Otherwise a later export could let that
        // stale canvas publish its annotations into the replacement document.
        CaptureEditingSession.commitPendingTextEdits()
        guard !preserveExisting || preserveDocumentBeforeReplacement() else { return false }
        importRequestID = UUID()
        invalidateDocumentActivities()
        document = CaptureDocument(image: image, sourceURL: sourceURL, createdAt: Date())
        currentHistoryItem = nil
        finishEditingError = nil
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
            currentHistoryItem = try persistEditableDocument(document, preview: data)
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

        appendUndo(EditSnapshot(document: document, annotations: oldValue))
        annotationRedoStack.removeAll()
    }

    private func appendUndo(_ snapshot: EditSnapshot) {
        annotationUndoStack.append(snapshot)
        if annotationUndoStack.count > maxUndoDepth {
            annotationUndoStack.removeFirst(annotationUndoStack.count - maxUndoDepth)
        }
    }

    private func resetAnnotations() {
        isApplyingAnnotationHistory = true
        annotations.removeAll()
        isApplyingAnnotationHistory = false
        annotationUndoStack.removeAll()
        annotationRedoStack.removeAll()
        selectedAnnotationID = nil
        cropSelection = nil
        if selectedTool == .crop { selectedTool = .select }
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
        try await PreciseScreenCapture.shared.capture(mode)
    }

    static func defaultTextRecognitionOperation(_ image: CGImage) async throws -> OCRResult {
        let languages = UserDefaults.standard.stringArray(forKey: RecognitionSettings.key) ?? []
        return try await TextRecognitionService().recognizeTextAsync(in: image, languages: languages)
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

    static func defaultFailurePresentationOperation(title: String, message: String) {
        CaptureFailurePresenter.shared.present(title: title, message: message)
    }

    private func reportFailure(_ message: String, title: String) {
        statusMessage = message
        NSSound.beep()
        failurePresentationOperation(title, message)
    }

    private func reportHistoryLoadFailureIfNeeded() {
        if let error = historyStore.loadError {
            reportFailure(error.localizedDescription, title: L10n.historyLoadFailedTitle)
        }
    }

    private static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8.0"
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
        reportFailure(error.localizedDescription, title: L10n.updateCheckFailedTitle)
    }

    private func presentUploadFailure(_ error: Error) {
        reportFailure(error.localizedDescription, title: L10n.uploadFailedTitle)
    }
}
