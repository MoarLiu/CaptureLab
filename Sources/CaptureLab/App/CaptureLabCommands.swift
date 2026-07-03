import AppKit
import SwiftUI

struct CaptureLabCommands: Commands {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcutStore: CaptureShortcutStore
    let showMainWindow: () -> Void

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(model.isCheckingForUpdates ? L10n.checkingForUpdates : L10n.checkForUpdates) {
                model.checkForUpdates()
            }
            .disabled(model.isCheckingForUpdates)

            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button(L10n.captureRegion) {
                model.captureRegion()
            }
            .keyboardShortcut(
                shortcutStore.captureShortcut.keyEquivalent,
                modifiers: shortcutStore.captureShortcut.modifiers
            )
            .disabled(model.isCapturing)

            Button(L10n.openImage) {
                model.openImage()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model.isCapturing)

            Divider()

            Button(L10n.showCaptureLab) {
                showMainWindow()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button(L10n.saveEditedImage) {
                model.saveRenderedImage()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.hasImage)

            Button(L10n.copyEditedImage) {
                model.copyRenderedImage()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!model.hasImage)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(L10n.undoMarkup) {
                model.undoAnnotation()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndoAnnotation)

            Button(L10n.clearMarkups) {
                model.clearAnnotations()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.annotations.isEmpty)
        }

        CommandMenu(L10n.captureMenu) {
            Button(L10n.captureRegion) {
                model.captureRegion()
            }
            .disabled(model.isCapturing)

            Button(L10n.openImage) {
                model.openImage()
            }
            .disabled(model.isCapturing)

            Divider()

            Button(L10n.copyEditedImage) {
                model.copyRenderedImage()
            }
            .disabled(!model.hasImage)

            Button(L10n.saveEditedImage) {
                model.saveRenderedImage()
            }
            .disabled(!model.hasImage)
        }

        CommandMenu(L10n.toolsMenu) {
            ForEach(CaptureTool.allCases) { tool in
                Button {
                    model.selectedTool = tool
                } label: {
                    Label(tool.title, systemImage: tool.systemImage)
                }
                .keyboardShortcut(tool.menuShortcut, modifiers: .command)
                .disabled(!model.hasImage && tool != .select)
            }

            Divider()

            Button(L10n.runOCR) {
                model.recognizeText()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.hasImage || model.isRecognizingText)

            Button(L10n.copyOCRText) {
                model.copyOCRText()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(L10n.clearOCRText) {
                model.clearOCRText()
            }
            .disabled(model.ocrText.isEmpty)
        }
    }
}

struct CaptureLabMenuBarView: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcutStore: CaptureShortcutStore
    let showMainWindow: () -> Void
    let showShortcutSettings: () -> Void

    var body: some View {
        Button(L10n.showCaptureLab, action: showMainWindow)

        Divider()

        Button(L10n.captureRegion) {
            showMainWindow()
            model.captureRegion()
        }
        .disabled(model.isCapturing)

        Button(L10n.shortcutConfiguration) {
            showShortcutSettings()
        }

        Text(L10n.shortcutSummary(shortcutStore.captureShortcut.displayTitle))
            .font(.caption)
            .foregroundStyle(.secondary)

        Button(L10n.openImage) {
            showMainWindow()
            model.openImage()
        }
        .disabled(model.isCapturing)

        Button(model.isCheckingForUpdates ? L10n.checkingForUpdates : L10n.checkForUpdates) {
            model.checkForUpdates()
        }
        .disabled(model.isCheckingForUpdates)

        Divider()

        Menu(L10n.toolsMenu) {
            ForEach(CaptureTool.allCases) { tool in
                Button {
                    showMainWindow()
                    model.selectedTool = tool
                } label: {
                    Label(tool.title, systemImage: tool.systemImage)
                }
                .disabled(!model.hasImage && tool != .select)
            }
        }

        Button(L10n.undoMarkup) {
            showMainWindow()
            model.undoAnnotation()
        }
        .disabled(!model.canUndoAnnotation)

        Button(L10n.clearMarkups) {
            showMainWindow()
            model.clearAnnotations()
        }
        .disabled(model.annotations.isEmpty)

        Divider()

        Button(L10n.runOCR) {
            showMainWindow()
            model.recognizeText()
        }
        .disabled(!model.hasImage || model.isRecognizingText)

        Button(L10n.copyEditedImage) {
            model.copyRenderedImage()
        }
        .disabled(!model.hasImage)

        Button(L10n.saveEditedImage) {
            showMainWindow()
            model.saveRenderedImage()
        }
        .disabled(!model.hasImage)

        Divider()

        Button(L10n.quitCaptureLab) {
            NSApp.terminate(nil)
        }
    }
}

private extension CaptureTool {
    var menuShortcut: KeyEquivalent {
        switch self {
        case .select:
            return "1"
        case .arrow:
            return "2"
        case .rectangle:
            return "3"
        case .brush:
            return "4"
        case .text:
            return "5"
        case .mosaic:
            return "6"
        }
    }
}
