import AppKit
import SwiftUI

struct CaptureWorkflowSettingsView: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var settings: CaptureWorkflowSettings
    @ObservedObject var history: CaptureHistoryStore
    @State private var retention = CaptureHistoryRetention.default
    @State private var failure: String?
    @State private var didSaveRetention = false

    init(model: CaptureLabViewModel) {
        self.model = model
        settings = model.workflowSettings
        history = model.historyStore
    }

    var body: some View {
        Form {
            Section(L10n.text(en: "After capture", zh: "截图完成后")) {
                Picker(L10n.text(en: "Action", zh: "默认操作"), selection: $settings.options.afterCapture) {
                    ForEach(CaptureAfterAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(L10n.text(en: "Captures are copied and added to history in every mode. Your current editor stays open in overlay and copy-only modes.",
                    zh: "所有模式都会复制截图并保存历史。浮层和仅复制模式保留当前编辑内容。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.overlayTitle) {
                Picker(L10n.text(en: "Position", zh: "显示位置"), selection: $settings.options.corner) {
                    ForEach(CaptureOverlayCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L10n.text(en: "Width", zh: "浮层宽度"), selection: $settings.options.overlayWidth) {
                    ForEach([280, 320, 400], id: \.self) { Text("\($0) pt").tag($0) }
                }
                Picker(L10n.text(en: "Auto-close", zh: "自动关闭"), selection: $settings.options.autoCloseSeconds) {
                    Text(L10n.text(en: "Never", zh: "不自动关闭")).tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { Text(L10n.text(en: "\($0) seconds", zh: "\($0) 秒")).tag($0) }
                }
                Toggle(L10n.text(en: "Follow the capture screen", zh: "跟随截图结束时鼠标所在屏幕"), isOn: $settings.options.followsCaptureScreen)
                Text(L10n.text(en: "Auto-close pauses while hovering, dragging or capturing. Disable screen following to use the primary display.",
                    zh: "鼠标停留、拖出图片或截图期间暂停自动关闭。关闭跟随时使用主屏幕。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text(en: "Capture history", zh: "历史保留")) {
                Picker(L10n.text(en: "Maximum captures", zh: "最多保留"), selection: $retention.maximumCount) {
                    ForEach([30, 100, 300], id: \.self) { Text(L10n.text(en: "\($0) captures", zh: "\($0) 张")).tag($0) }
                }
                Picker(L10n.text(en: "Maximum age", zh: "保留期限"), selection: Binding(
                    get: { retention.maximumAgeDays ?? 0 },
                    set: { retention.maximumAgeDays = $0 == 0 ? nil : $0 }
                )) {
                    Text(L10n.text(en: "No time limit", zh: "不按时间清理")).tag(0)
                    ForEach([1, 7, 30], id: \.self) { Text(L10n.text(en: "\($0) days", zh: "\($0) 天")).tag($0) }
                }
                Text(L10n.text(en: "Captures exceeding either limit are removed. Changes show the number affected before deleting anything.",
                    zh: "超过数量或期限的记录会被清理。应用设置前会显示本次将清理的数量。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text(en: "Apply Retention", zh: "应用保留设置"), action: applyRetention)
                    if didSaveRetention { Text(L10n.text(en: "Saved", zh: "已保存")).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 620)
        .onAppear {
            model.refreshHistory()
            retention = history.retention
        }
        .onChange(of: settings.options) { model.overlayController.updateOptions($0) }
        .onChange(of: retention) { _ in didSaveRetention = false }
        .alert(L10n.historySaveFailedTitle, isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.ok) { failure = nil }
        } message: { Text(failure ?? "") }
        .captureLabWindowCloseShortcuts()
    }

    private func applyRetention() {
        do {
            var preview = try history.previewRetention(retention)
            while true {
                if !preview.removingIDs.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = L10n.text(en: "Remove \(preview.removingIDs.count) captures?", zh: "清理 \(preview.removingIDs.count) 张历史截图？")
                    alert.informativeText = L10n.text(en: "Their local history images will be deleted. Exported files are not affected.", zh: "将删除这些历史记录及其本地图片，已另存的文件不受影响。")
                    alert.addButton(withTitle: L10n.cancel)
                    alert.addButton(withTitle: L10n.historyDelete)
                    guard alert.captureLabRunModal() == .alertSecondButtonReturn else { return }
                }
                if let changed = try history.applyRetention(preview) { preview = changed }
                else { break }
            }
            model.refreshHistory()
            didSaveRetention = true
        } catch { failure = error.localizedDescription }
    }
}
