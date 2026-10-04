import AppKit
import SwiftUI

struct CaptureLabCommands: Commands {
    @ObservedObject var model: CaptureLabViewModel
    let showMainWindow: () -> Void
    let showHistory: () -> Void
    let showR2Settings: () -> Void
    let showShortcutSettings: () -> Void
    let showRecognitionSettings: () -> Void
    var showWorkflowSettings: () -> Void = {}

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.workflowSettings, action: showWorkflowSettings)
                .keyboardShortcut(",", modifiers: .command)
            Menu(L10n.otherSettings) {
                CaptureOtherSettingsItems(showShortcutSettings: showShortcutSettings,
                    showRecognitionSettings: showRecognitionSettings, showR2Settings: showR2Settings)
            }
        }
        CommandGroup(after: .appInfo) {
            CaptureUpdateButton(model: model)
            Divider()
        }
        CommandGroup(replacing: .newItem) {
            CaptureOpenMenuItems(model: model, showEditor: showMainWindow, usesKeyboardShortcuts: true)
            Button(L10n.addImagesToCanvas) {
                showMainWindow()
                model.addImages()
            }.disabled(!model.canStartCapture)
        }
        CommandGroup(replacing: .saveItem) {
            CaptureSaveMenuItems(model: model, showEditor: showMainWindow, usesKeyboardShortcuts: true)
            Menu(L10n.shareMenu) {
                CaptureShareMenuItems(model: model, usesKeyboardShortcuts: true)
            }.disabled(!model.hasImage || !model.canStartCapture)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.undoEdit, action: model.undoAnnotation)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndoAnnotation || !model.canStartCapture)
            Button(L10n.redoMarkup, action: model.redoAnnotation)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedoAnnotation || !model.canStartCapture)
        }
        // Keep the system pasteboard commands and text responder chain intact.
        CommandGroup(after: .pasteboard) {
            CapturePasteImageButton(model: model, showEditor: showMainWindow)
            Button(L10n.selectMultipleObjects) {
                showMainWindow()
                CaptureEditingSession.commitPendingTextEdits()
                model.isEditingObjects = true
                model.showsOutputPreview = false
            }.disabled(!model.hasImage || !model.canStartCapture)
            Button(L10n.clearMarkups, action: model.clearAnnotations)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.annotations.isEmpty || !model.canStartCapture)
        }
        CommandGroup(after: .windowArrangement) {
            Button(L10n.openEditor, action: showMainWindow)
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model.isCapturing)
            Button(L10n.historyBrowserTitle, action: showHistory)
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(model.isCapturing)
            Button(L10n.pinImage, action: model.pinCurrentCapture)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.hasImage || !model.canStartCapture)
        }
        CommandMenu(L10n.captureMenu) {
            CaptureBasicMenuItems(model: model, showEditor: showMainWindow)
            Button(L10n.lastRegion) { model.capture(.lastRegion, onSuccess: showMainWindow) }
                .disabled(!model.canStartCapture)
            Menu(L10n.moreCapture) {
                CaptureMoreMenuItems(model: model, showEditor: showMainWindow, includesLastRegion: false)
            }.disabled(!model.canStartCapture)
        }
        CommandMenu(L10n.toolsMenu) {
            CaptureToolMenuItems(model: model, tools: [.select, .crop], showEditor: showMainWindow)
            Menu(L10n.lineAndShapeTools) {
                CaptureToolMenuItems(model: model,
                    tools: [.arrow, .curvedArrow, .line, .rectangle, .ellipse, .filledRectangle], showEditor: showMainWindow)
            }.disabled(!model.hasImage || !model.canStartCapture)
            Menu(L10n.textAndMarkTools) {
                CaptureToolMenuItems(model: model, tools: [.text, .counter, .brush, .highlight], showEditor: showMainWindow)
            }.disabled(!model.hasImage || !model.canStartCapture)
            Menu(L10n.visualEffectTools) {
                CaptureToolMenuItems(model: model, tools: [.mosaic, .blur, .spotlight], showEditor: showMainWindow)
            }.disabled(!model.hasImage || !model.canStartCapture)
            Menu(L10n.recognitionMenu) {
                CaptureRecognitionMenuItems(model: model, showEditor: showMainWindow, usesKeyboardShortcuts: true)
            }
        }
    }
}

struct CaptureLabMenuBarView: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcutStore: CaptureShortcutStore
    @ObservedObject var globalHotKeyController: GlobalHotKeyController
    let showMainWindow: () -> Void
    let showHistory: () -> Void
    let showShortcutSettings: () -> Void
    let showR2Settings: () -> Void
    let showRecognitionSettings: () -> Void
    var showWorkflowSettings: () -> Void = {}

    var body: some View {
        // Display the Carbon shortcut without registering another SwiftUI binding.
        CaptureBasicMenuItems(model: model, showEditor: showMainWindow,
            regionTitle: L10n.captureRegion + "  " + shortcutStore.captureShortcut.displayTitle)
        Menu(L10n.moreCapture) {
            CaptureMoreMenuItems(model: model, showEditor: showMainWindow)
        }.disabled(!model.canStartCapture)
        Menu(L10n.recognitionMenu) {
            CaptureRecognitionMenuItems(model: model, showEditor: showMainWindow)
        }
        Divider()
        Button(L10n.openEditor, action: showMainWindow).disabled(model.isCapturing)
        Menu(L10n.recentAndHistory) {
            if model.historyItems.isEmpty {
                Text(L10n.noRecentCaptures)
            } else {
                ForEach(Array(model.historyItems.prefix(8))) { item in
                    Button(item.displayTitle) {
                        showMainWindow()
                        model.openHistoryItem(item)
                    }.disabled(!model.canStartCapture)
                }
                Divider()
            }
            Button(L10n.showAllHistory, action: showHistory).disabled(model.isCapturing)
        }
        Menu(L10n.openAndPaste) {
            CaptureOpenMenuItems(model: model, showEditor: showMainWindow)
            CapturePasteImageButton(model: model, showEditor: showMainWindow)
        }.disabled(!model.canStartCapture)
        Menu(L10n.currentImageMenu) {
            Button(L10n.copyImage) { model.copyRenderedImage() }
            CaptureSaveMenuItems(model: model, showEditor: showMainWindow)
            Divider()
            CaptureUploadButton(model: model)
            Button(L10n.pinImage, action: model.pinCurrentCapture)
        }.disabled(!model.hasImage || !model.canStartCapture)
        Menu(L10n.overlaysAndPins) {
            CaptureOverlayMenu(controller: model.overlayController)
            Divider()
            CapturePinMenu()
        }.disabled(model.isCapturing)
        Divider()
        Menu(L10n.settingsMenu) {
            Button(L10n.captureAndHistorySettings, action: showWorkflowSettings)
            CaptureOtherSettingsItems(showShortcutSettings: showShortcutSettings,
                showRecognitionSettings: showRecognitionSettings, showR2Settings: showR2Settings)
        }
        if let error = globalHotKeyController.registrationError {
            Button(L10n.shortcutUnavailable, action: showShortcutSettings)
                .help(error)
                .accessibilityLabel(L10n.shortcutUnavailable + " " + error)
        }
        CaptureUpdateButton(model: model)
        Button(L10n.quitCaptureLab) { NSApp.terminate(nil) }
    }
}

private struct CaptureBasicMenuItems: View {
    @ObservedObject var model: CaptureLabViewModel
    let showEditor: () -> Void
    var regionTitle = L10n.captureRegion

    var body: some View {
        Button(regionTitle) { model.capture(.region, onSuccess: showEditor) }
            .disabled(!model.canStartCapture)
        Button(L10n.captureWindow) { model.capture(.window, onSuccess: showEditor) }
            .disabled(!model.canStartCapture)
        Button(L10n.captureFullScreen) { model.capture(.fullScreen, onSuccess: showEditor) }
            .disabled(!model.canStartCapture)
    }
}

private struct CaptureMoreMenuItems: View {
    @ObservedObject var model: CaptureLabViewModel
    let showEditor: () -> Void
    var includesLastRegion = true

    var body: some View {
        if includesLastRegion {
            Button(L10n.lastRegion) { model.capture(.lastRegion, onSuccess: showEditor) }
        }
        Button(L10n.frozenRegion) { model.capture(.frozenRegion, onSuccess: showEditor) }
        Button(L10n.captureDelayedRegion(3)) { model.capture(.delayedRegion(seconds: 3), onSuccess: showEditor) }
        Button(L10n.captureDelayedRegion(5)) { model.capture(.delayedRegion(seconds: 5), onSuccess: showEditor) }
        Button(L10n.captureLauncher) { model.performCaptureAction(.launcher) }
    }
}

private struct CaptureOpenMenuItems: View {
    @ObservedObject var model: CaptureLabViewModel
    let showEditor: () -> Void
    var usesKeyboardShortcuts = false

    var body: some View {
        Button(L10n.openImage) {
            showEditor()
            model.openImage()
        }.applicationMenuShortcut("o", enabled: usesKeyboardShortcuts)
            .disabled(!model.canStartCapture)
        Button(L10n.openProjectMenu) {
            showEditor()
            model.openProject()
        }.applicationMenuShortcut("o", modifiers: [.command, .shift], enabled: usesKeyboardShortcuts)
            .disabled(!model.canStartCapture)
    }
}

private struct CapturePasteImageButton: View {
    @ObservedObject var model: CaptureLabViewModel
    let showEditor: () -> Void
    var body: some View {
        Button(L10n.pasteImage) {
            model.pasteImage()
            if model.hasImage { showEditor() }
        }.disabled(!model.canStartCapture)
    }
}

private struct CaptureSaveMenuItems: View {
    @ObservedObject var model: CaptureLabViewModel
    let showEditor: () -> Void
    var usesKeyboardShortcuts = false

    var body: some View {
        Button(L10n.savePNGMenu) {
            showEditor()
            model.saveRenderedImage()
        }.applicationMenuShortcut("s", enabled: usesKeyboardShortcuts)
            .disabled(!model.hasImage || !model.canStartCapture)
        Button(L10n.exportImageMenu) {
            showEditor()
            model.prepareExport()
        }.applicationMenuShortcut("e", enabled: usesKeyboardShortcuts)
            .disabled(!model.hasImage || !model.canStartCapture)
        Button(L10n.saveProjectMenu) {
            showEditor()
            model.saveProject()
        }.applicationMenuShortcut("s", modifiers: [.command, .shift], enabled: usesKeyboardShortcuts)
            .disabled(!model.hasImage || !model.canStartCapture)
    }
}

private struct CaptureShareMenuItems: View {
    @ObservedObject var model: CaptureLabViewModel
    var usesKeyboardShortcuts = false
    var body: some View {
        Button(L10n.copyImage) { model.copyRenderedImage() }
            .applicationMenuShortcut("c", modifiers: [.command, .shift], enabled: usesKeyboardShortcuts)
        CaptureUploadButton(model: model, usesKeyboardShortcuts: usesKeyboardShortcuts)
    }
}

private struct CaptureUploadButton: View {
    @ObservedObject var model: CaptureLabViewModel
    var usesKeyboardShortcuts = false
    var body: some View {
        Button(model.isUploading ? L10n.uploading : L10n.uploadToR2) { model.uploadRenderedImage() }
            .applicationMenuShortcut("u", modifiers: [.command, .shift], enabled: usesKeyboardShortcuts)
            .disabled(model.isUploading || !model.hasImage || !model.canStartCapture)
    }
}

private struct CaptureRecognitionMenuItems: View {
    @ObservedObject var model: CaptureLabViewModel
    let showEditor: () -> Void
    var usesKeyboardShortcuts = false
    var body: some View {
        Button(L10n.directText) { model.performCaptureAction(.text) }.disabled(!model.canStartCapture)
        Button(L10n.directQRCode) { model.performCaptureAction(.qrCode) }.disabled(!model.canStartCapture)
        Divider()
        Button(L10n.recognizeCurrentImage) {
            showEditor()
            model.recognizeText()
        }.applicationMenuShortcut("r", modifiers: [.command, .shift], enabled: usesKeyboardShortcuts)
            .disabled(!model.hasImage || model.isRecognizingText || !model.canStartCapture)
        Button(L10n.copyOCRText, action: model.copyOCRText)
            .applicationMenuShortcut("c", modifiers: [.command, .option], enabled: usesKeyboardShortcuts)
            .disabled(model.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canStartCapture)
        Button(L10n.clearOCRText, action: model.clearOCRText)
            .disabled(model.ocrText.isEmpty || !model.canStartCapture)
    }
}

private struct CaptureToolMenuItems: View {
    @ObservedObject var model: CaptureLabViewModel
    let tools: [CaptureTool]
    let showEditor: () -> Void
    var body: some View {
        ForEach(tools) { tool in
            Button {
                showEditor()
                CaptureEditingSession.commitPendingTextEdits()
                model.selectedTool = tool
            } label: {
                Label(tool.title, systemImage: tool.systemImage)
            }.keyboardShortcut(tool.menuShortcut, modifiers: .command)
                .disabled(!model.canStartCapture || (!model.hasImage && tool != .select))
        }
    }
}

private struct CaptureOtherSettingsItems: View {
    let showShortcutSettings: () -> Void
    let showRecognitionSettings: () -> Void
    let showR2Settings: () -> Void
    var body: some View {
        Button(L10n.shortcutConfiguration, action: showShortcutSettings)
        Button(L10n.recognitionLanguages, action: showRecognitionSettings)
        Button(L10n.cloudflareR2SettingsMenuItem, action: showR2Settings)
    }
}

private struct CaptureUpdateButton: View {
    @ObservedObject var model: CaptureLabViewModel
    var body: some View {
        Button(model.isCheckingForUpdates ? L10n.checkingForUpdates : L10n.checkForUpdates, action: model.checkForUpdates)
            .disabled(!model.canStartCapture)
    }
}

private extension View {
    @ViewBuilder func applicationMenuShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command,
                                               enabled: Bool) -> some View {
        if enabled { keyboardShortcut(key, modifiers: modifiers) }
        else { self }
    }
}

private extension CaptureTool {
    var menuShortcut: KeyEquivalent {
        switch self {
        case .select:
            return "1"
        case .arrow:
            return "2"
        case .line:
            return "3"
        case .rectangle:
            return "4"
        case .counter:
            return "5"
        case .brush:
            return "6"
        case .text:
            return "7"
        case .highlight:
            return "8"
        case .mosaic:
            return "9"
        case .crop:
            return "k"
        case .ellipse: return "l"
        case .filledRectangle: return "f"
        case .curvedArrow: return "j"
        case .spotlight: return "t"
        case .blur: return "b"
        }
    }
}

private struct CaptureOverlayMenu: View {
    @ObservedObject var controller: CaptureQuickAccessController
    var body: some View {
        Button(L10n.overlayRestore, action: controller.restoreLast)
            .disabled(controller.lastClosed == nil)
        Button(controller.isTemporarilyHidden ? L10n.overlayShow : L10n.overlayHide, action: controller.toggleHidden)
            .disabled(controller.entries.isEmpty)
    }
}

private struct CapturePinMenu: View {
    @ObservedObject var controller = CapturePinController.shared
    var body: some View {
        Button(L10n.pinUnlockAll, action: controller.unlockAll).disabled(controller.windows.isEmpty)
        Button(L10n.pinCloseAll, action: controller.closeAll).disabled(controller.windows.isEmpty)
    }
}
