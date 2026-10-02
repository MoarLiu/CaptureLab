import AppKit
import SwiftUI

struct CaptureLauncherView: View {
    @ObservedObject var model: CaptureLabViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.captureLauncher).font(.title2)
            ForEach(CaptureAction.allCases.filter { $0 != .launcher }) { action in
                Button(action.title) { model.performCaptureAction(action) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isCapturing)
            }
            Button(L10n.captureDelayedRegion(5)) { model.capture(.delayedRegion(seconds: 5)) }.disabled(model.isCapturing)
            Button(L10n.frozenRegion) { model.capture(.frozenRegion) }.disabled(model.isCapturing)
            Text(L10n.text(en: "Region selection: drag, enter a size or ratio, then press Return. Escape cancels.",
                zh: "区域选择：拖动框选或输入尺寸、比例，回车确认，Esc 取消。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 360).captureLabWindowCloseShortcuts()
    }
}

struct DirectRecognitionView: View {
    @ObservedObject var controller: DirectRecognitionController
    @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text(en: "Recognition Results", zh: "识别结果")).font(.title2)
                Spacer()
                if controller.isRunning { ProgressView().controlSize(.small) }
            }
            Text(controller.failure ?? controller.message)
                .foregroundColor(controller.failure == nil ? .secondary : .red)
            List(controller.results, id: \.self, selection: $selected) { value in
                Text(value).lineLimit(8).textSelection(.enabled).tag(value)
            }.frame(minHeight: 180)
            HStack {
                Button(L10n.cancel) { controller.cancel() }.disabled(!controller.isRunning)
                Spacer()
                Button(L10n.copyOCRText) { if let selected { controller.copy(selected) } }
                    .disabled(selected == nil || controller.isRunning)
            }
        }.padding(20).frame(minWidth: 500, minHeight: 300)
        .onChange(of: controller.results) { selected = $0.first }
        .onAppear { selected = controller.results.first }
        .onDisappear { controller.cancel() }
        .captureLabWindowCloseShortcuts()
    }
}

struct RecognitionSettingsView: View {
    @StateObject private var settings = RecognitionSettings()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.recognitionLanguages).font(.title2)
            Text(L10n.text(en: "Languages available in Vision on this Mac. Empty selection uses available Chinese and English languages with automatic detection.",
                zh: "以下为本机 Vision 支持的语言。未选择时使用系统支持的中英文并自动检测。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error = settings.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(L10n.text(en: "Automatic", zh: "自动")) { settings.select([]) }
                Button(L10n.text(en: "Chinese + English", zh: "中英文")) { settings.select(["zh-Hans", "zh-Hant", "en-US"]) }
                Button(L10n.text(en: "Japanese + English", zh: "日英文")) { settings.select(["ja-JP", "en-US"]) }
            }
            List(settings.supported, id: \.self) { language in
                Toggle((Locale.current.localizedString(forIdentifier: language) ?? language) + " (\(language))", isOn: Binding(
                    get: { settings.languages.contains(language) },
                    set: { selected in
                        settings.select(selected ? settings.languages + [language] : settings.languages.filter { $0 != language })
                    }))
            }
        }.padding(20).frame(width: 460, height: 440).captureLabWindowCloseShortcuts()
    }
}

struct PrecisionCaptureMenu: View {
    @ObservedObject var model: CaptureLabViewModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L10n.captureLauncher) { model.presentCaptureLauncher?() }.disabled(model.isCapturing)
        Button(L10n.lastRegion) { model.capture(.lastRegion) }.disabled(model.isCapturing)
        Button(L10n.frozenRegion) { model.capture(.frozenRegion) }.disabled(model.isCapturing)
        Button(L10n.directText) { model.performCaptureAction(.text) }.disabled(model.isCapturing)
        Button(L10n.directQRCode) { model.performCaptureAction(.qrCode) }.disabled(model.isCapturing)
        Button(L10n.recognitionLanguages) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "recognition-settings")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
