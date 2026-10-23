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
    @State private var showsLayers = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: model.showsEditorOptions ? 94 : 53)

            HStack(spacing: 0) {
                CaptureEditorCanvasHost(model: model, zoomLevel: $zoomLevel)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                if showsLayers, !model.showsOutputPreview, let document = model.document {
                    Divider()
                    GeometryReader { proxy in
                    ScrollView {
                    VStack(spacing: 12) {
                        CaptureLayersView(document: document, annotations: model.annotations,
                            selectedObjects: model.selectedObjects, onSelectionChanged: { model.selectedObjects = $0 },
                            onCommit: { model.commitObjects(layers: $0, annotations: $1) }, addImages: model.addImages,
                            editAnnotation: { id in
                                model.selectedTool = .select
                                model.selectAnnotation(id)
                                model.isEditingObjects = false
                            })
                    }.padding(12).frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    }.frame(width: 280).background(Color(nsColor: .windowBackgroundColor))
                }
            }

            Divider()
            HStack(spacing: 12) {
                Text(model.hasImage ? model.documentTitle + " · " + model.imageDimensionsTitle : L10n.ready)
                    .help(model.hasImage ? model.documentTitle + " · " + model.imageDimensionsTitle : L10n.ready)
                Spacer(minLength: 8)
                if model.isUploading || model.isRecognizingText {
                    ProgressView().controlSize(.small)
                    Text(model.isUploading ? L10n.uploading : L10n.recognizingText)
                }
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
        .onAppear { showsLayers = model.isEditingObjects && model.hasImage }
        .onChange(of: model.isEditingObjects) { active in
            showsLayers = active
        }
        .onChange(of: model.selectedTool) { tool in
            if tool != .select { showsLayers = false }
        }
        .onChange(of: model.successFeedback) { feedback in
            if let feedback { showToast(feedback.message) }
        }
        .sheet(item: $model.exportRequest) { request in
            CaptureExportView(image: request.image, defaultFileName: request.fileName)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                EditorTopBarView(
                    model: model,
                    copyAction: copyImageFromToolbar,
                    uploadAction: uploadImageFromToolbar,
                    doneAction: finishEditing,
                    isOCRPopoverPresented: $isOCRPopoverPresented,
                    zoomLevel: $zoomLevel,
                    showsLayers: $showsLayers,
                    showHistory: showHistory
                )
                Divider()
                if model.showsEditorOptions {
                    EditorOptionsBarView(model: model)
                    Divider()
                }
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
        _ = model.copyRenderedImage(successStatus: L10n.copiedToClipboard)
    }

    private func uploadImageFromToolbar() {
        model.uploadRenderedImage()
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
    let copyAction: () -> Void
    let uploadAction: () -> Void
    let doneAction: () -> Void
    @Binding var isOCRPopoverPresented: Bool
    @Binding var zoomLevel: CaptureZoomLevel
    @Binding var showsLayers: Bool
    let showHistory: () -> Void
    @State private var showSize = false
    @State private var showAdvancedStyle = false
    @State private var showPresentation = false
    @State private var presentationSource: NSImage?
    @State private var presentationDocumentID: UUID?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            toolbar(includesSecondaryActions: true)
            toolbar(includesSecondaryActions: false)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(CaptureWindowDragRegion())
        .sheet(isPresented: $showSize) { CaptureImageAdjustmentView(model: model) }
        .sheet(isPresented: $showPresentation) {
            if let document = model.document {
                CapturePresentationView(presentation: .constant(document.presentation), sourceSize: document.pixelSize,
                    sourceImage: presentationSource, onApply: { presentation in
                        guard model.document?.id == presentationDocumentID else { return }
                        model.applyPresentation(presentation)
                    })
            }
        }
        .onChange(of: model.document?.id) { id in
            if showPresentation, id != presentationDocumentID { showPresentation = false }
        }
    }

    private func toolbar(includesSecondaryActions: Bool) -> some View {
        HStack(spacing: 10) {
            // Reserve all three native window buttons, including their drag area.
            Spacer().frame(width: 88)
            HStack(spacing: 6) {
                ToolbarIconButton(systemImage: "viewfinder", help: L10n.captureRegion, isPrimary: false) { model.captureRegion() }
                    .disabled(!model.canStartCapture)
                ToolbarIconButton(systemImage: "photo.badge.plus", help: L10n.openImage, isPrimary: false) { model.openImage() }
                    .disabled(model.isCapturing).keyboardShortcut("o", modifiers: .command)
            }
            if model.hasImage { ToolStripView(model: model, showAdvancedStyle: $showAdvancedStyle) }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                ZoomToolbarMenu(zoomLevel: $zoomLevel)
                if includesSecondaryActions {
                    ToolbarIconButton(systemImage: "arrow.uturn.backward", help: L10n.undoEdit, isPrimary: false, action: model.undoAnnotation)
                        .disabled(!model.canUndoAnnotation)
                    ToolbarIconButton(systemImage: "arrow.uturn.forward", help: L10n.redoMarkup, isPrimary: false, action: model.redoAnnotation)
                        .disabled(!model.canRedoAnnotation)
                }
                ToolbarIconButton(systemImage: "square.3.layers.3d",
                                  help: showsLayers ? L10n.text(en: "Hide Layers", zh: "收起图层面板") : L10n.text(en: "Show Layers", zh: "展开图层面板"),
                                  isPrimary: showsLayers) {
                    CaptureEditingSession.commitPendingTextEdits()
                    showsLayers.toggle()
                    model.isEditingObjects = showsLayers
                    if showsLayers { model.showsOutputPreview = false }
                }.disabled(!model.hasImage).accessibilityAddTraits(showsLayers ? [.isSelected] : [])
                ToolbarIconButton(systemImage: "photo.artframe", help: L10n.text(en: "Background and templates", zh: "背景与模板"), isPrimary: false) {
                    presentationSource = model.renderedContentImage()
                    presentationDocumentID = model.document?.id
                    showPresentation = presentationSource != nil
                }.disabled(!model.hasImage)
                if includesSecondaryActions {
                    OCRToolbarButton(model: model, isPresented: $isOCRPopoverPresented)
                    ToolbarIconButton(systemImage: "doc.on.doc.fill", help: L10n.copyImage, isPrimary: false, action: copyAction)
                        .disabled(!model.hasImage)
                }
                Button(action: model.saveRenderedImage) {
                    Text(L10n.savePNGMenu).font(.system(size: 12, weight: .semibold))
                        .fixedSize().padding(.horizontal, 10).frame(height: 28)
                }.buttonStyle(EditorCapsuleButtonStyle()).disabled(!model.hasImage)
                Button(action: doneAction) {
                    Text(L10n.copyAndClose).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).fixedSize().padding(.horizontal, 10).frame(height: 28)
                }.buttonStyle(EditorDoneButtonStyle()).disabled(!model.hasImage)
                    .help(L10n.text(en: "Save the editable history, copy the image and close this editor window.", zh: "保存可编辑历史、复制成品，并关闭当前编辑器窗口。"))
                actionsMenu
            }.layoutPriority(3)
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button(L10n.copyImage, action: copyAction).disabled(!model.hasImage)
            Button(L10n.ocr) {
                if model.ocrText.isEmpty { model.recognizeText() }
                isOCRPopoverPresented = true
            }.disabled(!model.hasImage || model.isRecognizingText)
            Button(model.isUploading ? L10n.uploading : L10n.uploadToR2, action: uploadAction)
                .disabled(!model.hasImage || model.isUploading)
            Button(L10n.pinImage, action: model.pinCurrentCapture).disabled(!model.hasImage)
            Button(L10n.exportImageMenu, action: model.prepareExport).disabled(!model.hasImage)
            Divider()
            Button(L10n.undoEdit, action: model.undoAnnotation).disabled(!model.canUndoAnnotation)
            Button(L10n.redoMarkup, action: model.redoAnnotation).disabled(!model.canRedoAnnotation)
            Button(L10n.text(en: "Add Images…", zh: "添加图片…"), action: model.addImages).disabled(!model.hasImage)
            Menu(L10n.text(en: "Image Adjustments", zh: "图片调整")) {
                Button(L10n.text(en: "Output Size…", zh: "输出尺寸…")) { showSize = true }
                Button(L10n.text(en: "Rotate 90° Clockwise", zh: "顺时针旋转 90°")) { model.adjustImage(.rotateClockwise) }
                Button(L10n.text(en: "Flip Horizontally", zh: "水平翻转")) { model.adjustImage(.flipHorizontal) }
                Button(L10n.text(en: "Flip Vertically", zh: "垂直翻转")) { model.adjustImage(.flipVertical) }
            }.disabled(!model.hasImage)
            Divider()
            Button(model.showsOutputPreview ? L10n.text(en: "Return to Editing", zh: "返回编辑") : L10n.previewOutput) {
                CaptureEditingSession.commitPendingTextEdits()
                model.showsOutputPreview.toggle()
            }.disabled(!model.hasImage)
            Button(L10n.pasteImage, action: model.pasteImage)
            Button(L10n.saveProjectMenu, action: model.saveProject).disabled(!model.hasImage)
            Button(L10n.openProjectMenu, action: model.openProject)
            Button(L10n.historyBrowserTitle, action: showHistory)
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L10n.text(en: "Image Actions", zh: "图片操作"))
        .accessibilityLabel(L10n.text(en: "Image Actions", zh: "图片操作"))
        .popover(isPresented: $isOCRPopoverPresented, arrowEdge: .bottom) {
            OCRPopoverView(model: model).frame(width: 340, height: 260)
        }
    }
}

private struct EditorOptionsBarView: View {
    @ObservedObject var model: CaptureLabViewModel
    @State private var showCropSize = false

    var body: some View {
        HStack(spacing: 12) {
            if model.selectedTool == .crop { cropControls }
            else {
                ScrollView(.horizontal, showsIndicators: false) { appearanceControls }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appearanceControls: some View {
        HStack(spacing: 14) {
            if canEditColor {
                ColorPicker(L10n.annotationColor, selection: colorBinding, supportsOpacity: false)
                    .fixedSize().disabled(!model.hasImage)
            }
            if canEditLineWidth {

            Stepper(value: lineWidthBinding, in: 1...32, step: 1) {
                Text("\(L10n.annotationLineWidth) \(Int(lineWidthBinding.wrappedValue))")
                    .monospacedDigit()
                    .frame(minWidth: 62, alignment: .leading)
            }
            .fixedSize()
            .disabled(!model.hasImage || !canEditLineWidth)
            .accessibilityLabel(L10n.annotationLineWidth)
            }
            if canEditFontSize {

            Stepper(value: fontSizeBinding, in: 8...144, step: 1) {
                Text("\(L10n.annotationFontSize) \(Int(fontSizeBinding.wrappedValue))")
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .leading)
            }
            .fixedSize()
            .disabled(!model.hasImage || !canEditFontSize)
            .accessibilityLabel(L10n.annotationFontSize)
            }

            if editingTool != .select {
            Text(editingTool == .blur || editingTool == .mosaic ? L10n.redactionHint
                 : model.selectedAnnotationID == nil ? L10n.newAnnotationAppearanceHint : L10n.selectedAnnotationAppearanceHint)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(editingTool == .blur || editingTool == .mosaic ? L10n.redactionGuidance : L10n.annotationAppearanceHelp)
            }

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
            Text(L10n.cropImage).font(.system(size: 12, weight: .medium))
            Menu(L10n.text(en: "Crop Options", zh: "裁剪选项")) {
                Picker(L10n.text(en: "Ratio", zh: "比例"), selection: $model.cropPreset) {
                    ForEach(CaptureCropPreset.allCases) { Text($0.title).tag($0) }
                }
                Button(L10n.text(en: "Exact Size…", zh: "精确尺寸…")) { showCropSize = true }
            }
            .onChange(of: model.cropPreset) { _ in model.constrainCropSelection() }
            .sheet(isPresented: $showCropSize) { CaptureImageAdjustmentView(model: model, isCrop: true) }
            Button(L10n.cropApply) { _ = model.applyCrop() }
                .disabled(!model.canApplyCrop)
                .help(L10n.cropHelp)

            Button(L10n.cancel, action: model.cancelCrop)

            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(L10n.cropHelp)
        }
    }

    private var editingTool: CaptureTool { model.annotationEditingTool }

    private var canEditColor: Bool { ![.select, .mosaic, .crop, .blur, .spotlight].contains(editingTool) }
    private var canEditLineWidth: Bool {
        [.arrow, .line, .rectangle, .brush, .ellipse, .filledRectangle, .curvedArrow].contains(editingTool)
    }
    private var canEditFontSize: Bool { [.text, .counter].contains(editingTool) }

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
                .background(Color.primary.opacity(0.045), in: Capsule())
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
    @Binding var showAdvancedStyle: Bool
    private var visibleTools: [CaptureTool] {
        let common: [CaptureTool] = [.select, .arrow, .rectangle, .text, .mosaic]
        return common.contains(model.selectedTool) ? common : common + [model.selectedTool]
    }
    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(visibleTools) { tool in
                        ToolbarToolButton(tool: tool, isSelected: model.selectedTool == tool,
                            isDisabled: !model.hasImage && tool != .select) { model.selectedTool = tool }
                    }
                }
            }.frame(width: CGFloat(visibleTools.count) * 34 - 2, height: 28)
            Menu {
                ForEach(CaptureTool.allCases) { tool in
                    Button { model.selectedTool = tool } label: { Label(tool.title, systemImage: tool.systemImage) }
                }
                Divider()
                Button(L10n.text(en: "Annotation Style…", zh: "标注样式…")) { showAdvancedStyle = true }
                    .disabled(model.annotationEditingTool == .select || model.annotationEditingTool == .crop)
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                .help(L10n.moreTools)
                .accessibilityLabel(L10n.moreTools)
                .popover(isPresented: $showAdvancedStyle) {
                    CaptureAdvancedAnnotationStyleView(appearance: $model.annotationAppearance, tool: model.annotationEditingTool,
                        highlightAlignmentAction: model.recognizeHighlightRegions)
                }
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
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.055))
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
