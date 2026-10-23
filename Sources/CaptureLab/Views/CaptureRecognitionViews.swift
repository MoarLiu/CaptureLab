import AppKit
import SwiftUI

struct CaptureLauncherView: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcuts: CaptureShortcutStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.captureLauncher).font(.system(size: 20, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                choice(.region, symbol: "viewfinder")
                choice(.window, symbol: "macwindow")
                choice(.fullScreen, symbol: "display")
                choice(.lastRegion, symbol: "arrow.counterclockwise")
                choice(.delayedRegion, symbol: "timer")
                modeChoice(.frozenRegion, symbol: "snowflake")
                choice(.text, symbol: "text.viewfinder")
                choice(.qrCode, symbol: "qrcode")
                modeChoice(.preciseRegion, symbol: "ruler")
            }
            Text(L10n.text(en: "Choose a capture mode.", zh: "选择一种截图方式。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 440).captureLabWindowCloseShortcuts()
    }
    private func choice(_ action: CaptureAction, symbol: String) -> some View {
        tile(action.title, symbol: symbol, shortcut: shortcuts.shortcut(for: action)?.displayTitle) {
            model.performCaptureAction(action)
        }
    }
    private func modeChoice(_ mode: CaptureMode, symbol: String) -> some View {
        tile(mode.title, symbol: symbol, shortcut: nil) { model.capture(mode) }
    }
    private func tile(_ title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            Task { @MainActor in await Task.yield(); action() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(Color.accentColor)
                    Spacer()
                    if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(!model.canStartCapture)
    }
}

struct DirectRecognitionView: View {
    @ObservedObject var controller: DirectRecognitionController
    let startSelection: (DirectRecognitionController.Kind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(en: "Recognition Results", zh: "识别结果")).font(.title2.weight(.semibold))
            if controller.isRunning {
                stateContent {
                    ProgressView().controlSize(.large)
                    Text(L10n.recognizingText).font(.headline)
                    Text(copyAvailability).foregroundStyle(.secondary)
                }
            } else if let failure = controller.failure {
                stateContent {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(Color.red)
                    Text(L10n.text(en: "Recognition failed", zh: "识别失败")).font(.headline)
                    Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                    selectionButton
                }
            } else if controller.results.isEmpty {
                stateContent {
                    Image(systemName: "text.viewfinder").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(controller.lastKind == nil
                         ? L10n.text(en: "Select an area to recognize text or QR codes", zh: "框选区域以识别文字或二维码")
                         : controller.message).font(.headline)
                    selectionButton
                }
            } else {
                Text(controller.message).foregroundStyle(.secondary)
                List(controller.results, id: \.self, selection: $selected) { value in
                    Text(value).lineLimit(8).textSelection(.enabled).tag(value)
                }.frame(minHeight: 180)
            }
            HStack {
                if controller.isRunning {
                    Button(L10n.cancel) { controller.cancel() }
                } else if !controller.results.isEmpty {
                    selectionButton
                }
                Spacer()
                Button(L10n.copyOCRText) { if let selected { controller.copy(selected) } }
                    .disabled(!canCopy).help(copyAvailability).accessibilityHint(copyAvailability)
            }
        }.padding(24).frame(minWidth: 500, minHeight: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.results) { selected = $0.first }
        .onAppear { selected = controller.results.first }
        .onDisappear { controller.cancel() }
        .captureLabWindowCloseShortcuts()
    }

    private var canCopy: Bool { !controller.isRunning && selected.map(controller.results.contains) == true }
    private var copyAvailability: String {
        controller.isRunning
            ? L10n.text(en: "Copy will be available when recognition finishes.", zh: "识别完成后即可复制结果。")
            : canCopy ? L10n.copyOCRText : L10n.text(en: "Select a recognized result to copy.", zh: "有识别结果并选中后即可复制。")
    }
    private func stateContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14, content: content).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 20)
    }
    private var selectionButton: some View {
        HStack(spacing: 12) {
            Button(controller.lastKind == nil ? L10n.text(en: "Select Text Area", zh: "开始框选识字")
                   : L10n.text(en: "Select Area Again", zh: "重新框选")) {
                select(controller.lastKind ?? .text)
            }.buttonStyle(.borderedProminent)
            Menu(L10n.text(en: "Recognition Mode", zh: "识别方式")) {
                Button(L10n.text(en: "Recognize Text", zh: "框选识字")) { select(.text) }
                Button(L10n.text(en: "Recognize QR Code", zh: "识别二维码")) { select(.qrCode) }
            }.fixedSize()
        }
    }
    private func select(_ kind: DirectRecognitionController.Kind) {
        controller.cancel()
        dismiss()
        Task { @MainActor in
            await Task.yield()
            startSelection(kind)
        }
    }
}
