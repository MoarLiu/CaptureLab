import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CapturePresentationView: View {
    @Binding var presentation: CapturePresentation
    let sourceSize: CGSize
    var sourceImage: NSImage? = nil
    var onApply: (CapturePresentation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CapturePresentation()
    @StateObject private var presets = CapturePresentationStore()
    @State private var presetID: UUID?
    @State private var presetName = ""
    @State private var errorMessage: String?
    @State private var previewImage: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L10n.text(en: "Background & Layout", zh: "背景与布局")).font(.headline)
                Spacer()
                Button(L10n.text(en: "Reset", zh: "重置")) { draft = CapturePresentation() }
            }
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        backgroundControls
                        Divider()
                        layoutControls
                        Divider()
                        presetControls
                    }.padding(.trailing, 8)
                }.frame(width: 340, height: 530)
                preview.frame(width: 290, height: 530)
            }
            if let message = errorMessage ?? presets.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L10n.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text(en: "Apply", zh: "应用")) { onApply(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.outputSize(for: sourceSize) == nil)
            }
        }
        .padding(20).textFieldStyle(.roundedBorder)
        .onAppear { draft = presentation }
        .task(id: draft) { await updatePreview() }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text(en: "Background", zh: "背景"), selection: $draft.background) {
                ForEach(CaptureBackgroundKind.allCases) { Text($0.title).tag($0) }
            }
            switch draft.background {
            case .transparent: EmptyView()
            case .solid:
                colorPicker(L10n.text(en: "Color", zh: "颜色"), color: $draft.color)
            case .gradient:
                colorPicker(L10n.text(en: "Start color", zh: "起始颜色"), color: $draft.color)
                colorPicker(L10n.text(en: "End color", zh: "终止颜色"), color: $draft.secondaryColor)
                slider(L10n.text(en: "Angle", zh: "角度"), value: $draft.gradientAngle, range: 0...360, unit: "°")
            case .builtIn:
                Picker(L10n.text(en: "Style", zh: "风格"), selection: $draft.builtIn) {
                    ForEach(CaptureBuiltInBackground.allCases) { Text($0.title).tag($0) }
                }
            case .image:
                Button(L10n.text(en: "Choose background image…", zh: "选择背景图片…")) { chooseBackground() }
                if let name = draft.customBackgroundName { Text(name).font(.caption).lineLimit(2) }
                Text(L10n.text(en: "The image is embedded in the project and fills the background with a centered crop.", zh: "图片随项目保存，居中裁切以铺满背景。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text(en: "Output ratio", zh: "输出比例"), selection: $draft.aspect) {
                ForEach(CapturePresentationAspect.allCases) { Text($0.title).tag($0) }
            }
            if draft.aspect == .custom {
                HStack {
                    TextField(L10n.text(en: "Ratio width", zh: "比例宽度"), value: $draft.customAspectWidth, format: .number)
                        .accessibilityLabel(L10n.text(en: "Ratio width", zh: "比例宽度"))
                    Text(":")
                    TextField(L10n.text(en: "Ratio height", zh: "比例高度"), value: $draft.customAspectHeight, format: .number)
                        .accessibilityLabel(L10n.text(en: "Ratio height", zh: "比例高度"))
                }
            }
            slider(L10n.text(en: "Padding", zh: "留白"), value: $draft.padding, range: 0...512)
            Button(L10n.text(en: "Balance padding automatically", zh: "自动平衡留白")) { draft.balancePadding(for: sourceSize) }
                .help(L10n.text(en: "Center the content and add equal minimum margins based on its size.", zh: "依据内容尺寸添加相等的最小留白，并将内容居中。"))
            slider(L10n.text(en: "Corner radius", zh: "圆角"), value: $draft.cornerRadius, range: 0...256)
            slider(L10n.text(en: "Shadow opacity", zh: "阴影浓度"), value: $draft.shadowOpacity, range: 0...1, unit: "%", multiplier: 100)
            if draft.shadowOpacity > 0 {
                slider(L10n.text(en: "Shadow blur", zh: "阴影模糊"), value: $draft.shadowBlur, range: 0...128)
                slider(L10n.text(en: "Shadow offset", zh: "阴影偏移"), value: $draft.shadowOffset, range: -64...64)
            }
            Picker(L10n.text(en: "Alignment", zh: "对齐"), selection: $draft.alignment) {
                ForEach(CapturePresentationAlignment.allCases) { Text($0.title).tag($0) }
            }
            Text(L10n.text(en: "Layout adds space around the finished image. Annotations keep their positions within the image.", zh: "布局在合成图片周围增加空间，标注在图片内的位置保持不变。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(en: "Personal presets", zh: "个人样式预设")).font(.subheadline.bold())
            HStack {
                Picker(L10n.text(en: "Preset", zh: "预设"), selection: $presetID) {
                    Text(L10n.text(en: "Select a preset", zh: "选择预设")).tag(Optional<UUID>.none)
                    ForEach(presets.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Button(L10n.text(en: "Apply", zh: "应用")) {
                    if let preset = presets.presets.first(where: { $0.id == presetID }) { draft = preset.presentation }
                }.disabled(presetID == nil)
                Button(role: .destructive) {
                    guard let presetID else { return }
                    do { try presets.delete(presetID); self.presetID = nil; errorMessage = nil }
                    catch { errorMessage = error.localizedDescription }
                } label: { Image(systemName: "trash") }
                    .accessibilityLabel(L10n.text(en: "Delete preset", zh: "删除预设"))
                    .disabled(presetID == nil)
            }
            HStack {
                TextField(L10n.text(en: "New preset name", zh: "新预设名称"), text: $presetName)
                    .accessibilityLabel(L10n.text(en: "New preset name", zh: "新预设名称"))
                Button(L10n.text(en: "Save preset", zh: "保存预设")) {
                    do {
                        presetID = try presets.save(name: presetName, presentation: draft).id
                        presetName = ""; errorMessage = nil
                    } catch { errorMessage = error.localizedDescription }
                }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private var preview: some View {
        VStack(spacing: 14) {
            Text(L10n.text(en: "Preview", zh: "预览")).font(.subheadline.bold())
            ZStack {
                Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                if let previewImage {
                    Image(nsImage: previewImage).resizable().interpolation(.high).scaledToFit().padding(8)
                } else {
                    Text(L10n.text(en: "Choose a valid layout to preview.", zh: "选择有效的布局后显示预览。"))
                        .foregroundStyle(.secondary).padding()
                }
            }.frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 8))
            if let size = draft.outputSize(for: sourceSize) {
                Text("\(Int(size.width)) × \(Int(size.height)) px").monospacedDigit()
            } else {
                Text(L10n.text(en: "Invalid background or dimensions", zh: "背景或尺寸无效")).foregroundStyle(.red)
            }
            Spacer()
        }
    }
    private func colorPicker(_ title: String, color: Binding<CaptureRGBAColor>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(nsColor: color.wrappedValue.nsColor) },
                                             set: { color.wrappedValue = CaptureRGBAColor(NSColor($0)) }), supportsOpacity: true)
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "px", multiplier: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int((value.wrappedValue * multiplier).rounded())) \(unit)").foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            draft.customBackgroundData = try CaptureImageImport.data(from: url)
            draft.customBackgroundName = url.lastPathComponent
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    private func updatePreview() async {
        let requested = draft
        previewImage = nil
        guard let source = sourceImage?.captureLabCGImage() else {
            previewImage = nil
            return
        }
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
            let result = try await CaptureExportWorker.shared.render(CaptureExportImage(image: source), presentation: requested)
            try Task.checkCancellation()
            guard requested == draft else { return }
            previewImage = NSImage(cgImage: result.image, size: CGSize(width: result.image.width, height: result.image.height))
            errorMessage = nil
        } catch is CancellationError { }
        catch { guard !Task.isCancelled, requested == draft else { return }; previewImage = nil; errorMessage = error.localizedDescription }
    }
}
