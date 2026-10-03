import AppKit
import SwiftUI

@MainActor
struct CaptureExportView: View {
    let image: NSImage
    var defaultFileName = "CaptureLab"
    @Environment(\.dismiss) private var dismiss
    @State private var settings = CaptureExportSettings()
    @State private var encodedData: Data?
    @State private var encodedSettings: CaptureExportSettings?
    @State private var encodedImage: NSImage?
    @State private var errorMessage: String?
    @State private var isEncoding = false
    @State private var isSaving = false
    @State private var initialized = false
    private let store = CaptureExportSettingsStore()

    private var inputSize: CGSize { image.captureLabPixelSize }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(en: "Export Image", zh: "导出图片")).font(.headline)
            HStack(alignment: .top, spacing: 24) {
                controls.frame(width: 290)
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .underPageBackgroundColor))
                        if let encodedImage {
                            Image(nsImage: encodedImage).resizable().interpolation(.high).scaledToFit().padding(8)
                        }
                        if isEncoding { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                    }.frame(width: 300, height: 280)
                    if let encodedData, encodedSettings == settings {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(encodedData.count), countStyle: .file)).font(.headline).monospacedDigit()
                        Text(L10n.text(en: "Actual encoded size; this preview is the file that will be saved.", zh: "实际编码大小；保存文件与当前预览使用同一份数据。"))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else if isEncoding {
                        Text(L10n.text(en: "Calculating file size…", zh: "正在计算文件大小…")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(width: 300)
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L10n.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text(en: "Save…", zh: "保存…")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isEncoding || encodedData == nil || encodedSettings != settings)
            }
        }
        .padding(20).textFieldStyle(.roundedBorder)
        .onAppear {
            var restored = store.load()
            restored.matchAspectRatio(to: inputSize)
            settings = restored; initialized = true
        }
        .task(id: initialized ? settings : nil) { if initialized { await updatePreview() } }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L10n.text(en: "Format", zh: "格式"), selection: $settings.format) {
                ForEach(CaptureExportFormat.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if settings.format == .jpeg {
                HStack {
                    Text(L10n.text(en: "Quality", zh: "质量")); Spacer()
                    Text("\(Int(settings.quality * 100))%").monospacedDigit()
                }
                Slider(value: $settings.quality, in: 0.05...1, step: 0.01)
                    .accessibilityLabel(L10n.text(en: "JPEG quality", zh: "JPEG 质量"))
                ColorPicker(L10n.text(en: "JPEG background", zh: "JPEG 背景色"), selection: Binding(
                    get: { Color(nsColor: settings.matte.nsColor) },
                    set: { settings.matte = CaptureRGBAColor(NSColor($0)) }), supportsOpacity: false)
                Text(L10n.text(en: "JPEG has no transparency. Transparent pixels are filled with the background color shown above.", zh: "JPEG 不支持透明。透明像素会填充为上方明确显示的背景色。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text(en: "PNG preserves transparent pixels and uses lossless compression.", zh: "PNG 保留透明像素，使用无损压缩。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            dimensionField(L10n.text(en: "Width", zh: "宽度"), isWidth: true)
            dimensionField(L10n.text(en: "Height", zh: "高度"), isWidth: false)
            Toggle(L10n.text(en: "Keep aspect ratio", zh: "保持比例"), isOn: $settings.keepAspectRatio)
                .onChange(of: settings.keepAspectRatio) { value in
                    if value { settings.matchAspectRatio(to: inputSize) }
                }
            Button(L10n.text(en: "Use original size", zh: "使用原始尺寸")) { settings.width = nil; settings.height = nil }
            Text(L10n.text(en: "The last successfully saved configuration is reused for the next export.", zh: "下次导出会复用最近一次成功保存的配置。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func dimensionField(_ title: String, isWidth: Bool) -> some View {
        HStack {
            Text(title).frame(width: 44, alignment: .leading)
            TextField("px", value: Binding(
                get: { isWidth ? (settings.width ?? Int(inputSize.width)) : (settings.height ?? Int(inputSize.height)) },
                set: { setDimension($0, isWidth: isWidth) }), format: .number.grouping(.never))
                .frame(width: 100).accessibilityLabel(title)
            Text("px").foregroundStyle(.secondary)
        }
    }
    private func setDimension(_ value: Int, isWidth: Bool) {
        if isWidth { settings.width = value } else { settings.height = value }
        settings.matchAspectRatio(to: inputSize, usingWidth: isWidth)
    }
    private func updatePreview() async {
        let requested = settings
        encodedData = nil; encodedSettings = nil; encodedImage = nil; isEncoding = true; errorMessage = nil
        guard let source = image.captureLabCGImage() else {
            errorMessage = CapturePresentationError.encodingFailed.localizedDescription; isEncoding = false; return
        }
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
            let data = try await CaptureExportWorker.shared.encode(CaptureExportImage(image: source), settings: requested)
            try Task.checkCancellation()
            guard requested == settings else { return }
            encodedData = data; encodedSettings = requested
            encodedImage = NSImage(data: data)
            isEncoding = false
        } catch is CancellationError { }
        catch { guard !Task.isCancelled, requested == settings else { return }; errorMessage = error.localizedDescription; isEncoding = false; encodedImage = nil }
    }
    private func save() {
        guard let data = encodedData, encodedSettings == settings, !isEncoding, !isSaving else { return }
        let requested = settings
        let panel = NSSavePanel()
        panel.allowedContentTypes = [requested.format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = URL(fileURLWithPath: defaultFileName).deletingPathExtension().lastPathComponent + "." + requested.format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isSaving = true
        do {
            try data.write(to: url, options: .atomic)
            store.save(requested)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }
}
