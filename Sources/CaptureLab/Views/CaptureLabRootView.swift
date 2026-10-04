import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CaptureLabRootView: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcutStore: CaptureShortcutStore
    let showHistory: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isOCRPopoverPresented = false
    @State private var window: NSWindow?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var zoomLevel: CaptureZoomLevel = .fit

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 98)

            CaptureEditorCanvasHost(model: model, zoomLevel: $zoomLevel)
                .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 12) {
                if model.hasImage {
                    Picker(L10n.text(en: "Editor view", zh: "编辑视图"), selection: Binding(
                        get: { model.showsOutputPreview ? 2 : (model.isEditingObjects ? 1 : 0) },
                        set: { mode in
                            CaptureEditingSession.commitPendingTextEdits()
                            model.showsOutputPreview = mode == 2
                            model.isEditingObjects = mode == 1
                        })) {
                        Text(L10n.text(en: "Annotate", zh: "标注")).tag(0)
                        Text(L10n.text(en: "Objects", zh: "图层")).tag(1)
                        Text(L10n.text(en: "Output", zh: "预览")).tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
                Text(model.statusMessage).help(model.statusMessage)
                Spacer(minLength: 8)
                Menu(L10n.text(en: "Project", zh: "项目")) {
                    Button(L10n.text(en: "Open Project…", zh: "打开项目…"), action: model.openProject)
                    Button(L10n.text(en: "Save Editable Project…", zh: "保存可编辑项目…"), action: model.saveProject)
                        .disabled(!model.hasImage)
                }.fixedSize().disabled(model.isCapturing)
                Button(L10n.pasteImage, action: model.pasteImage)
                    .disabled(model.isCapturing)
                CaptureImageDragSource(snapshot: model.renderedSnapshot, isEnabled: model.hasImage)
                    .frame(width: 28, height: 26)
            }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowChromeConfigurator())
        .background(CaptureImagePasteInstaller(paste: model.pasteImage))
        .onDrop(of: [UTType.fileURL, .image], isTargeted: nil, perform: model.importDroppedImage)
        .background(CaptureWindowReader(window: $window))
        .background(CaptureDocumentCloseGuard(model: model))
        .sheet(item: $model.exportRequest) { request in
            CaptureExportView(image: request.image, defaultFileName: request.fileName)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                EditorTopBarView(
                    model: model,
                    shortcutStore: shortcutStore,
                    copyAction: copyImageFromToolbar,
                    uploadAction: uploadImageFromToolbar,
                    doneAction: finishEditing,
                    isOCRPopoverPresented: $isOCRPopoverPresented,
                    zoomLevel: $zoomLevel
                )
                Divider()
                EditorOptionsBarView(model: model, showHistory: showHistory)
                Divider()
            }
            .zIndex(100)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                CopyToastView(message: toastMessage)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(200)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .captureLabWindowCloseShortcuts(onEscape: {
            if model.selectedTool == .crop {
                model.cancelCrop()
            } else if let window {
                window.performClose(nil)
            } else if model.preserveDocumentBeforeReplacement() {
                dismiss()
            }
        })
        .alert(L10n.finishEditingFailedTitle, isPresented: Binding(
            get: { model.finishEditingError != nil },
            set: { if !$0 { model.finishEditingError = nil } }
        )) {
            Button(L10n.ok, role: .cancel) { model.finishEditingError = nil }
        } message: {
            Text(model.finishEditingError ?? "")
        }
    }

    private func copyImageFromToolbar() {
        guard model.copyRenderedImage(successStatus: L10n.copiedToClipboard) else {
            return
        }
        showToast(L10n.copiedToClipboard)
    }

    private func uploadImageFromToolbar() {
        model.uploadRenderedImage { _ in
            showToast(L10n.uploadedURLCopied)
        }
    }

    private func finishEditing() {
        guard model.finishEditing() else {
            return
        }

        if let window {
            window.close()
        } else {
            dismiss()
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token

        withAnimation(.easeOut(duration: 0.16)) {
            toastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard toastToken == token else {
                return
            }
            withAnimation(.easeIn(duration: 0.18)) {
                toastMessage = nil
            }
        }
    }
}

private struct EditorTopBarView: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcutStore: CaptureShortcutStore
    let copyAction: () -> Void
    let uploadAction: () -> Void
    let doneAction: () -> Void
    @Binding var isOCRPopoverPresented: Bool
    @Binding var zoomLevel: CaptureZoomLevel

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
                .frame(width: 88)

            HStack(spacing: 6) {
                ToolbarIconButton(systemImage: "viewfinder", help: L10n.captureRegion, isPrimary: false) {
                    model.captureRegion()
                }
                .disabled(model.isCapturing)

                ToolbarIconButton(systemImage: "photo.badge.plus", help: L10n.openImage, isPrimary: false) {
                    model.openImage()
                }
                .disabled(model.isCapturing)
                .keyboardShortcut("o", modifiers: .command)
            }

            if model.hasImage {
                ToolStripView(model: model)
            }

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                ZoomToolbarMenu(zoomLevel: $zoomLevel)

                OCRToolbarButton(
                    model: model,
                    isPresented: $isOCRPopoverPresented
                )

                ToolbarIconButton(systemImage: "doc.on.doc.fill", help: L10n.copyImage, isPrimary: false) {
                    copyAction()
                }
                .disabled(!model.hasImage)

                ToolbarIconButton(
                    systemImage: model.isUploading ? "hourglass" : "icloud.and.arrow.up.fill",
                    help: model.isUploading ? L10n.uploading : L10n.upload,
                    isPrimary: false,
                    action: uploadAction
                )
                .disabled(!model.hasImage || model.isUploading)

                Button {
                    model.prepareExport()
                } label: {
                    Text(L10n.saveAs)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 58, height: 28)
                }
                .buttonStyle(EditorCapsuleButtonStyle())
                .disabled(!model.hasImage)
                .layoutPriority(3)

                Button(action: doneAction) {
                    Text(L10n.done)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 58, height: 28)
                }
                .buttonStyle(EditorDoneButtonStyle())
                .disabled(!model.hasImage)
                .layoutPriority(3)
            }
            .layoutPriority(3)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .background(CaptureWindowDragRegion())
    }
}

private struct EditorOptionsBarView: View {
    @ObservedObject var model: CaptureLabViewModel
    let showHistory: () -> Void
    @State private var showSize = false
    @State private var showCropSize = false
    @State private var showAdvancedStyle = false
    @State private var showLayers = false
    @State private var showPresentation = false
    @State private var presentationSource: NSImage?
    @State private var presentationDocumentID: UUID?


    var body: some View {
        HStack(spacing: 12) {
            if model.selectedTool == .crop {
                cropControls
            } else {
                ScrollView(.horizontal, showsIndicators: false) { appearanceControls }
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button { showAdvancedStyle = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help(L10n.text(en: "Advanced annotation styles", zh: "高级标注样式"))
                    .accessibilityLabel(L10n.text(en: "Advanced annotation styles", zh: "高级标注样式"))
                    .disabled(!model.hasImage)
                    .popover(isPresented: $showAdvancedStyle) {
                        CaptureAdvancedAnnotationStyleView(appearance: $model.annotationAppearance, tool: editingTool,
                            highlightAlignmentAction: model.recognizeHighlightRegions)
                    }
                Button {
                    CaptureEditingSession.commitPendingTextEdits()
                    model.isEditingObjects = true
                    model.showsOutputPreview = false
                    showLayers = true
                } label: { Image(systemName: "square.3.layers.3d") }
                    .help(L10n.text(en: "Objects and images", zh: "图层与图片"))
                    .accessibilityLabel(L10n.text(en: "Objects and images", zh: "图层与图片"))
                    .disabled(!model.hasImage)
                    .popover(isPresented: $showLayers) {
                        if let document = model.document {
                            CaptureLayersView(document: document, annotations: model.annotations,
                                selectedObjects: model.selectedObjects,
                                onSelectionChanged: { model.selectedObjects = $0 },
                                onCommit: { model.commitObjects(layers: $0, annotations: $1) }, addImages: model.addImages)
                                .frame(width: 340, height: 480)
                        }
                    }
                Button {
                    presentationSource = model.renderedContentImage()
                    presentationDocumentID = model.document?.id
                    showPresentation = presentationSource != nil
                } label: { Image(systemName: "photo.artframe") }
                    .help(L10n.text(en: "Background and templates", zh: "背景与模板"))
                    .accessibilityLabel(L10n.text(en: "Background and templates", zh: "背景与模板"))
                    .disabled(!model.hasImage)
                    .sheet(isPresented: $showPresentation) {
                        if let document = model.document {
                            CapturePresentationView(presentation: .constant(document.presentation), sourceSize: document.pixelSize,
                                sourceImage: presentationSource, onApply: { presentation in
                                    guard model.document?.id == presentationDocumentID else { return }
                                    model.applyPresentation(presentation)
                                })
                        }
                    }
                Menu {
                    Button(L10n.text(en: "Add Images…", zh: "添加图片…"), action: model.addImages)
                    Divider()
                    Button(L10n.text(en: "Output Size…", zh: "输出尺寸…")) { showSize = true }
                    Button(L10n.text(en: "Rotate 90° Clockwise", zh: "顺时针旋转 90°")) { model.adjustImage(.rotateClockwise) }
                    Button(L10n.text(en: "Flip Horizontally", zh: "水平翻转")) { model.adjustImage(.flipHorizontal) }
                    Button(L10n.text(en: "Flip Vertically", zh: "垂直翻转")) { model.adjustImage(.flipVertical) }
                } label: { Image(systemName: "rotate.right") }
                .menuStyle(.borderlessButton).frame(width: 28)
                .help(L10n.text(en: "Image adjustments", zh: "图片调整"))
                .accessibilityLabel(L10n.text(en: "Image adjustments", zh: "图片调整"))
                .disabled(!model.hasImage)
                .sheet(isPresented: $showSize) { CaptureImageAdjustmentView(model: model) }
                ToolbarIconButton(systemImage: "arrow.uturn.backward", help: L10n.undoEdit, isPrimary: false) {
                    model.undoAnnotation()
                }
                .disabled(!model.canUndoAnnotation)

                ToolbarIconButton(systemImage: "arrow.uturn.forward", help: L10n.redoMarkup, isPrimary: false) {
                    model.redoAnnotation()
                }
                .disabled(!model.canRedoAnnotation)

                Divider().frame(height: 20)

                ToolbarIconButton(systemImage: "pin.fill", help: L10n.pinImage, isPrimary: false) {
                    model.pinCurrentCapture()
                }
                .disabled(!model.hasImage)

                ToolbarIconButton(systemImage: "clock.arrow.circlepath", help: L10n.historyBrowserTitle, isPrimary: false, action: showHistory)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.document?.id) { id in
            if showPresentation, id != presentationDocumentID { showPresentation = false }
        }
    }

    private var appearanceControls: some View {
        HStack(spacing: 14) {
            ColorPicker(L10n.annotationColor, selection: colorBinding, supportsOpacity: false)
                .fixedSize()
                .disabled(!model.hasImage || !canEditColor)

            Stepper(value: lineWidthBinding, in: 1...32, step: 1) {
                Text("\(L10n.annotationLineWidth) \(Int(lineWidthBinding.wrappedValue))")
                    .monospacedDigit()
                    .frame(minWidth: 62, alignment: .leading)
            }
            .fixedSize()
            .disabled(!model.hasImage || !canEditLineWidth)
            .accessibilityLabel(L10n.annotationLineWidth)

            Stepper(value: fontSizeBinding, in: 8...144, step: 1) {
                Text("\(L10n.annotationFontSize) \(Int(fontSizeBinding.wrappedValue))")
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .leading)
            }
            .fixedSize()
            .disabled(!model.hasImage || !canEditFontSize)
            .accessibilityLabel(L10n.annotationFontSize)

            Text(editingTool == .blur || editingTool == .mosaic ? L10n.redactionHint
                 : model.selectedAnnotationID == nil ? L10n.newAnnotationAppearanceHint : L10n.selectedAnnotationAppearanceHint)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(editingTool == .blur || editingTool == .mosaic ? L10n.redactionGuidance : L10n.annotationAppearanceHelp)

            if model.hasImage {
                Text(model.documentTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.documentTitle)
            }
        }
    }

    private var cropControls: some View {
        HStack(spacing: 12) {
            Picker(L10n.text(en: "Ratio", zh: "比例"), selection: $model.cropPreset) {
                ForEach(CaptureCropPreset.allCases) { preset in Text(preset.title).tag(preset) }
            }.frame(width: 140)
            .onChange(of: model.cropPreset) { _ in model.constrainCropSelection() }
            Button(L10n.text(en: "Exact Size…", zh: "精确尺寸…")) { showCropSize = true }
                .sheet(isPresented: $showCropSize) { CaptureImageAdjustmentView(model: model, isCrop: true) }

            if let selection = model.cropSelection,
               let document = model.document,
               let rect = CaptureImageCrop.pixelRect(selection, pixelSize: document.canvasSize) {
                Text(L10n.cropPixelSize(width: Int(rect.width), height: Int(rect.height)))
                    .monospacedDigit()
            }

            Button(L10n.cropApply) { _ = model.applyCrop() }
                .disabled(!model.canApplyCrop)
                .help(L10n.cropHelp)

            Button(L10n.cancel, action: model.cancelCrop)

            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(L10n.cropHelp)
        }
    }

    private var editingTool: CaptureTool {
        guard let annotation = model.annotations.first(where: { $0.id == model.selectedAnnotationID }) else {
            return model.selectedTool
        }
        return CaptureTool(rawValue: annotation.kind.rawValue) ?? model.selectedTool
    }

    private var canEditColor: Bool { editingTool != .mosaic && editingTool != .crop }
    private var canEditLineWidth: Bool {
        [.select, .arrow, .line, .rectangle, .brush, .ellipse, .filledRectangle, .curvedArrow].contains(editingTool)
    }
    private var canEditFontSize: Bool { [.select, .text, .counter].contains(editingTool) }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: model.annotationAppearance.color?.nsColor ?? (editingTool == .highlight ? .systemYellow : .systemRed))
            },
            set: { model.annotationAppearance.color = CaptureAnnotationColor(NSColor($0)) }
        )
    }

    private var lineWidthBinding: Binding<CGFloat> {
        Binding(get: { model.annotationAppearance.lineWidth ?? 4 }, set: { model.annotationAppearance.lineWidth = $0 })
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(get: { model.annotationAppearance.fontSize ?? 24 }, set: { model.annotationAppearance.fontSize = $0 })
    }
}

private struct CopyToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)

            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
    }
}

private struct CaptureWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            window = nsView.window
        }
    }
}

private struct DocumentToolbarStatusView: View {
    @ObservedObject var model: CaptureLabViewModel

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: model.hasImage ? "photo" : "viewfinder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(model.hasImage ? model.documentTitle : L10n.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .frame(width: 190, height: 28)
            .background(Color.white.opacity(0.76), in: Capsule())
            .help(model.hasImage ? model.documentTitle : L10n.appName)
        }
    }
}

struct ZoomToolbarMenu: View {
    @Binding var zoomLevel: CaptureZoomLevel

    var body: some View {
        Menu {
            ForEach(CaptureZoomLevel.allCases) { level in
                Button {
                    zoomLevel = level
                } label: {
                    if zoomLevel == level {
                        Label(level.title, systemImage: "checkmark")
                    } else {
                        Text(level.title)
                    }
                }
            }
        } label: {
            Text(zoomLevel.title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 56, height: 28)
                .background(Color.white.opacity(0.72), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 12, weight: .semibold))
        .controlSize(.small)
        .fixedSize()
        .frame(width: 56, height: 28)
        .contentShape(Rectangle())
        .clipped()
        .help(L10n.zoom)
        .layoutPriority(3)
    }
}

private struct ToolStripView: View {
    @ObservedObject var model: CaptureLabViewModel
    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(CaptureTool.allCases) { tool in
                        ToolbarToolButton(tool: tool, isSelected: model.selectedTool == tool,
                            isDisabled: !model.hasImage && tool != .select) { model.selectedTool = tool }
                    }
                }
            }.frame(minWidth: 120, idealWidth: 370, maxWidth: 520, maxHeight: 28)
            Menu {
                ForEach(CaptureTool.allCases) { tool in
                    Button { model.selectedTool = tool } label: { Label(tool.title, systemImage: tool.systemImage) }
                }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).frame(width: 18)
                .help(L10n.toolsMenu)
                .accessibilityLabel(L10n.toolsMenu)
        }
        .padding(.horizontal, 5)
        .frame(height: 28)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct OCRToolbarButton: View {
    @ObservedObject var model: CaptureLabViewModel
    @Binding var isPresented: Bool

    var body: some View {
        ToolbarIconButton(systemImage: "text.viewfinder", help: L10n.ocr, isPrimary: false) {
            if model.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.recognizeText()
            }
            isPresented = true
        }
        .disabled(!model.hasImage || model.isRecognizingText)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            OCRPopoverView(model: model)
                .frame(width: 340, height: 260)
        }
    }
}

private struct OCRPopoverView: View {
    @ObservedObject var model: CaptureLabViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(L10n.ocr, systemImage: "text.viewfinder")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button(L10n.run) {
                    model.recognizeText()
                }
                .disabled(!model.hasImage || model.isRecognizingText)

                Button(L10n.copy) {
                    model.copyOCRText()
                }
                .disabled(model.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.ocrText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .disabled(model.isRecognizingText)

                if model.ocrText.isEmpty && !model.isRecognizingText {
                    Text(L10n.noOCRText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    var isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(EditorRoundButtonStyle(isPrimary: isPrimary))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ToolbarToolButton: View {
    let tool: CaptureTool
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)

                Image(systemName: tool.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(isDisabled ? 0.28 : 0.78))
            }
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(tool.title)
        .accessibilityLabel(tool.title)
    }
}

private struct EditorRoundButtonStyle: ButtonStyle {
    var isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(isPrimary ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1) : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.045))
            )
    }
}

private struct EditorCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.58 : 0.76))
            )
    }
}

private struct EditorDoneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.76 : 1))
            )
    }
}
