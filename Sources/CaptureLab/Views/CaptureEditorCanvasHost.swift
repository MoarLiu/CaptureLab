import AppKit
import SwiftUI

/// Editing uses source coordinates; output preview uses exactly the same frozen
/// composition as copy, export, pin, drag-out, history and upload.
struct CaptureEditorCanvasHost: View {
    @ObservedObject var model: CaptureLabViewModel
    @Binding var zoomLevel: CaptureZoomLevel
    @State private var error: String?

    var body: some View {
        Group {
            if model.showsOutputPreview, model.hasImage {
                CaptureRenderedPreview(model: model, zoomLevel: zoomLevel)
            } else if model.isEditingObjects, let document = model.document {
                GeometryReader { proxy in
                    let size = CaptureCanvasLayout.contentSize(imageSize: document.displaySize,
                        viewportSize: proxy.size, zoomLevel: zoomLevel)
                    if zoomLevel == .fit {
                        objectCanvas(document).frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            objectCanvas(document).frame(width: size.width, height: size.height)
                        }
                    }
                }
            } else {
                CaptureCanvasView(document: model.annotationCanvasDocument,
                    annotations: $model.annotations, selectedTool: $model.selectedTool,
                    zoomLevel: $zoomLevel, highlightTextRegions: model.highlightTextRegions,
                    annotationAppearance: model.annotationAppearance,
                    selectedAnnotationID: model.selectedAnnotationID, cropSelection: $model.cropSelection,
                    onSelectionChanged: model.selectAnnotation, cropPreset: model.cropPreset,
                    applyCrop: { _ = model.applyCrop() }, cancelCrop: model.cancelCrop,
                    captureAction: model.captureRegion, openAction: model.openImage)
            }
        }
        .alert(L10n.imageOpenFailedTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.ok, role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func objectCanvas(_ document: CaptureDocument) -> some View {
        CaptureLayersCanvasView(document: document, annotations: model.annotations,
            selection: model.selectedObjects, onSelectionChanged: { model.selectedObjects = $0 },
            onCommit: { model.commitObjects(layers: $0, annotations: $1) }, zoomLevel: zoomLevel,
            onError: { error = $0 })
    }
}

private struct CaptureRenderedPreview: View {
    @ObservedObject var model: CaptureLabViewModel
    let zoomLevel: CaptureZoomLevel
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    if let scale = zoomLevel.scale {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).resizable()
                                .frame(width: image.size.width * scale, height: image.size.height * scale)
                                .padding(30)
                                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                        }
                    } else {
                        Image(nsImage: image).resizable().scaledToFit().padding(30)
                    }
                } else if failed {
                    Text(L10n.imageExportFailed).foregroundStyle(.secondary)
                } else { ProgressView() }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.document?.id) { _ in refresh() }
        .onChange(of: model.annotations) { _ in refresh() }
    }

    private func refresh() {
        image = model.renderedSnapshot()?.image
        failed = image == nil
    }
}
