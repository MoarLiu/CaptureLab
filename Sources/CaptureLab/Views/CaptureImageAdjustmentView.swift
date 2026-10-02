import SwiftUI

struct CaptureImageAdjustmentView: View {
    @ObservedObject var model: CaptureLabViewModel
    var isCrop = false
    @Environment(\.dismiss) private var dismiss
    @State private var width = 1.0
    @State private var height = 1.0
    @State private var percentage = 100.0
    @State private var keepRatio = true
    @State private var usesPercent = false
    @State private var originalSize = CGSize(width: 1, height: 1)
    @State private var documentID: UUID?

    private var ratio: Double { originalSize.width / originalSize.height }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCrop ? L10n.text(en: "Exact Crop Size", zh: "精确裁剪尺寸") : L10n.text(en: "Output Size", zh: "输出尺寸"))
                .font(.headline)
            if !isCrop {
                Picker(L10n.text(en: "Unit", zh: "单位"), selection: $usesPercent) {
                    Text(L10n.text(en: "Pixels", zh: "像素")).tag(false)
                    Text(L10n.text(en: "Percent", zh: "百分比")).tag(true)
                }.pickerStyle(.segmented)
            }
            if usesPercent {
                HStack {
                    Text(L10n.text(en: "Scale", zh: "缩放"))
                    TextField("%", value: $percentage, format: .number).frame(width: 100)
                        .accessibilityLabel(L10n.text(en: "Scale percent", zh: "缩放百分比"))
                    Text("%")
                }
                Text("\(Int(safeDimension(originalSize.width * percentage / 100))) × \(Int(safeDimension(originalSize.height * percentage / 100))) px")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(L10n.text(en: "Width", zh: "宽度"))
                    TextField("px", value: Binding(get: { width }, set: {
                        width = $0
                        if keepRatio { height = ($0 / ratio).rounded() }
                    }), format: .number).frame(width: 100)
                        .accessibilityLabel(L10n.text(en: "Width in pixels", zh: "像素宽度"))
                    Text("px")
                }
                HStack {
                    Text(L10n.text(en: "Height", zh: "高度"))
                    TextField("px", value: Binding(get: { height }, set: {
                        height = $0
                        if keepRatio { width = ($0 * ratio).rounded() }
                    }), format: .number).frame(width: 100)
                        .accessibilityLabel(L10n.text(en: "Height in pixels", zh: "像素高度"))
                    Text("px")
                }
                Toggle(L10n.text(en: "Keep aspect ratio", zh: "保持比例"), isOn: $keepRatio)
                    .onChange(of: keepRatio) { value in if value { height = (width / ratio).rounded() } }
            }
            if isCrop {
                Text(L10n.text(en: "Dimensions use canvas pixels before output scaling. Move the selection, then apply the crop.", zh: "尺寸使用输出缩放前的画布像素。设置后可移动选区，再应用裁剪。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text(en: "Apply", zh: "应用")) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validSize || model.document?.id != documentID)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: 330)
        .onAppear {
            if let document = model.document {
                documentID = document.id
                originalSize = isCrop ? document.canvasSize : document.pixelSize
                width = originalSize.width
                height = originalSize.height
                if isCrop, let selection = model.cropSelection,
                   let rect = CaptureImageCrop.pixelRect(selection, pixelSize: originalSize) {
                    width = rect.width; height = rect.height
                    keepRatio = false
                }
            }
        }
    }

    private var requestedSize: CGSize {
        usesPercent ? CGSize(width: (originalSize.width * percentage / 100).rounded(),
                             height: (originalSize.height * percentage / 100).rounded())
                    : CGSize(width: width, height: height)
    }
    private var validSize: Bool {
        CaptureDocumentGeometry.validSize(requestedSize)
            && (!isCrop || (requestedSize.width <= originalSize.width && requestedSize.height <= originalSize.height))
    }
    private func safeDimension(_ value: Double) -> Double { value.isFinite ? min(max(value.rounded(), 0), 1_000_000) : 0 }
    private func apply() {
        guard model.document?.id == documentID, validSize else { return }
        if isCrop {
            let size = requestedSize
            let center = model.cropSelection.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 0.5, y: 0.5)
            model.cropPreset = .free
            model.cropSelection = CaptureCropGeometry.exactSelection(size: size, canvasSize: originalSize, center: center)
            dismiss()
        } else if model.resizeOutput(to: requestedSize) { dismiss() }
    }
}
