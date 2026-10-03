import SwiftUI

struct ScrollingCaptureView: View {
    @ObservedObject var controller: ScrollingCaptureController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(controller.direction.title).font(.headline)
                    Spacer()
                    Text(controller.dimensions).font(.caption).monospacedDigit()
                }
                Text(L10n.text(en: "\(controller.segmentCount) accepted frames · Direction is fixed for this session", zh: "已接收 \(controller.segmentCount) 帧 · 本次会话方向固定"))
                    .font(.caption).foregroundColor(.secondary)
                if let preview = controller.preview {
                    Image(nsImage: preview).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 200)
                        .background(Color.black.opacity(0.08))
                        .accessibilityLabel(L10n.text(en: "Accepted scrolling capture preview", zh: "已接收的滚动截图预览"))
                }
                if let pending = controller.pendingPreview {
                    Text(L10n.text(en: "Pending frame — not added", zh: "待处理画面 — 尚未添加")).font(.caption.bold())
                    Image(nsImage: pending).resizable().scaledToFit().frame(maxHeight: 100)
                        .accessibilityLabel(L10n.text(en: "Unmatched pending frame", zh: "尚未匹配的待处理画面"))
                }
                Text(controller.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(controller.isStopped ? .orange : .primary)
                    .accessibilityLabel(controller.message)
                HStack {
                    Button(controller.isPaused ? L10n.text(en: "Resume", zh: "继续") : L10n.text(en: "Pause", zh: "暂停")) { controller.togglePause() }
                        .disabled(controller.isStopped || controller.isBusy)
                        .keyboardShortcut("p", modifiers: [.command])
                    Button(L10n.text(en: "Finish", zh: "结束")) { controller.finish() }
                        .keyboardShortcut(.defaultAction).disabled(controller.isBusy)
                    Button(L10n.cancel) { controller.cancel() }.keyboardShortcut(.cancelAction)
                }
                Divider()
                Text(L10n.text(en: "Fixed bands (source pixels)", zh: "固定边栏（源图像像素）")).font(.subheadline.bold())
                HStack {
                    numericField(controller.direction == .vertical ? L10n.text(en: "Top", zh: "顶部") : L10n.text(en: "Left", zh: "左侧"), value: $controller.leadingBand)
                    numericField(controller.direction == .vertical ? L10n.text(en: "Bottom", zh: "底部") : L10n.text(en: "Right", zh: "右侧"), value: $controller.trailingBand)
                    Button(L10n.text(en: "Apply", zh: "应用")) { controller.applyBands() }
                }.disabled(controller.segmentCount > 1 || controller.isBusy)
                Text(L10n.text(en: "Set before scrolling. Fixed edges appear once in the output. Exclude sidebars and scrollbars when selecting the region.", zh: "滚动前设置；固定边栏在输出中仅出现一次。框选时请避开另一方向的侧栏和滚动条。"))
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Text(L10n.text(en: "Manual seam correction", zh: "手动纠正接缝")).font(.subheadline.bold())
                HStack {
                    numericField(L10n.text(en: "Added pixels", zh: "新增像素"), value: $controller.seamPixels)
                    Stepper("", value: $controller.seamPixels, in: 1...max(1, controller.maximumSeamPixels)).labelsHidden()
                    Button(L10n.text(en: "Apply seam", zh: "应用接缝")) { controller.adjustSeam() }
                }.disabled(controller.isBusy || (controller.segmentCount < 2 && controller.pendingPreview == nil))
                Text(L10n.text(en: "Applies to the pending frame, or the last accepted seam. Review the result before continuing.", zh: "应用于待处理画面，或最后已接收的接缝。继续前请检查结果。"))
                    .font(.caption).foregroundColor(.secondary)
                Button(L10n.text(en: "Discard last segment", zh: "丢弃最后一段")) { controller.discardLast() }
                    .disabled(controller.isBusy || (controller.segmentCount < 2 && controller.pendingPreview == nil))
                    .keyboardShortcut("z", modifiers: [.command])
                Text(L10n.text(en: "Limits: 32,768 px/side · 40 MP · 384 MiB · 10 minutes", zh: "限制：单边 32768 像素 · 4000 万像素 · 384 MiB · 10 分钟"))
                    .font(.caption2).foregroundColor(.secondary)
            }.padding(14)
        }.frame(minWidth: 350)
    }

    private func numericField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(minWidth: 55, maxWidth: 88)
                .accessibilityLabel(title)
        }
    }
}
