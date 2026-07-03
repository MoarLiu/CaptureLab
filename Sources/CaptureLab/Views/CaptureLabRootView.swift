import AppKit
import SwiftUI

struct CaptureLabRootView: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcutStore: CaptureShortcutStore
    @Environment(\.dismiss) private var dismiss
    @State private var isOCRPopoverPresented = false
    @State private var window: NSWindow?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 52)
            Divider()

            CaptureCanvasView(
                document: model.document,
                annotations: $model.annotations,
                selectedTool: $model.selectedTool,
                captureAction: model.captureRegion,
                openAction: model.openImage
            )
            .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowChromeConfigurator())
        .background(CaptureWindowReader(window: $window))
        .overlay(alignment: .top) {
            EditorTopBarView(
                model: model,
                shortcutStore: shortcutStore,
                copyAction: copyImageFromToolbar,
                doneAction: finishEditing,
                isOCRPopoverPresented: $isOCRPopoverPresented
            )
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
    }

    private func copyImageFromToolbar() {
        guard model.copyRenderedImage(successStatus: L10n.copiedToClipboard) else {
            return
        }
        showToast(L10n.copiedToClipboard)
    }

    private func finishEditing() {
        guard model.copyRenderedImage() else {
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
    let doneAction: () -> Void
    @Binding var isOCRPopoverPresented: Bool

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
                .frame(width: 88)

            HStack(spacing: 6) {
                ToolbarIconButton(systemImage: "crop", help: L10n.captureRegion, isPrimary: false) {
                    model.captureRegion()
                }
                .disabled(model.isCapturing)
                .keyboardShortcut(
                    shortcutStore.captureShortcut.keyEquivalent,
                    modifiers: shortcutStore.captureShortcut.modifiers
                )

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

            DocumentToolbarStatusView(model: model)

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                ZoomToolbarMenu()

                OCRToolbarButton(
                    model: model,
                    isPresented: $isOCRPopoverPresented
                )

                ToolbarIconButton(systemImage: "doc.on.doc.fill", help: L10n.copyImage, isPrimary: false) {
                    copyAction()
                }
                .disabled(!model.hasImage)

                ToolbarIconButton(systemImage: "icloud.and.arrow.up.fill", help: L10n.upload, isPrimary: false) {}
                    .disabled(true)

                Button {
                    model.saveRenderedImage()
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

private struct ZoomToolbarMenu: View {
    var body: some View {
        Menu {
            Button("50%") {}
            Button("100%") {}
            Button("200%") {}
        } label: {
            HStack(spacing: 4) {
                Text("100%")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, height: 28)
            .background(Color.white.opacity(0.72), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .help(L10n.zoom)
        .layoutPriority(3)
    }
}

private struct ToolStripView: View {
    @ObservedObject var model: CaptureLabViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CaptureTool.allCases) { tool in
                ToolbarToolButton(
                    tool: tool,
                    isSelected: model.selectedTool == tool,
                    isDisabled: !model.hasImage && tool != .select
                ) {
                    model.selectedTool = tool
                }

                if tool != CaptureTool.allCases.last {
                    Divider()
                        .frame(height: 22)
                        .padding(.horizontal, 1)
                }
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
