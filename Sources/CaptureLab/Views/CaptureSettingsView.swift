import AppKit
import SwiftUI

struct CaptureSettingsView: View {
    @ObservedObject var session: CaptureSettingsSession
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var shortcuts: CaptureShortcutStore
    @ObservedObject var hotKeys: GlobalHotKeyController
    @ObservedObject private var workflow: CaptureWorkflowSettings
    @StateObject private var recognition: RecognitionSettings
    let registerShortcut: (CaptureAction, CaptureKeyboardShortcut?) -> String?

    init(session: CaptureSettingsSession, model: CaptureLabViewModel, shortcuts: CaptureShortcutStore,
         hotKeys: GlobalHotKeyController, recognition: RecognitionSettings? = nil,
         registerShortcut: @escaping (CaptureAction, CaptureKeyboardShortcut?) -> String?) {
        self.session = session; self.model = model; self.shortcuts = shortcuts; self.hotKeys = hotKeys
        workflow = model.workflowSettings
        _recognition = StateObject(wrappedValue: recognition ?? RecognitionSettings())
        self.registerShortcut = registerShortcut
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "viewfinder").font(.system(size: 23, weight: .medium)).foregroundStyle(Color.accentColor)
                    Text(L10n.appName).font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 26)
                ForEach(CaptureSettingsSection.allCases.filter { $0 != .about }) { category in sidebarButton(category) }
                Spacer(minLength: 24)
                sidebarButton(.about)
            }
            .padding(12).frame(width: 200)
            .background(.regularMaterial)
            Divider()
            GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                // Retaining the page views also retains their independent scroll positions.
                settingsPage(.general) { CaptureGeneralSettingsPage(model: model, session: session, recognition: recognition) }
                settingsPage(.shortcuts) {
                    ShortcutSettingsView(shortcutStore: shortcuts, controller: hotKeys, session: session, onSave: registerShortcut)
                }
                settingsPage(.overlay) { CaptureOverlaySettingsPage(model: model, session: session) }
                settingsPage(.upload) { CaptureUploadSettingsPage(draft: session.upload) }
                settingsPage(.about) { CaptureAboutSettingsPage(model: model) }
            }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(CaptureSettingsCloseGuard(session: session))
        .captureLabWindowCloseShortcuts(onEscape: {
            if session.recordingAction != nil { session.recordingAction = nil }
            else { NSApp.keyWindow?.performClose(nil) }
        })
        .onDisappear { session.recordingAction = nil }
        .onChange(of: workflow.options) { model.overlayController.updateOptions($0) }
    }
    private func sidebarButton(_ category: CaptureSettingsSection) -> some View {
        Button { session.navigate(to: category) } label: {
            HStack(spacing: 10) {
                Image(systemName: category.symbol)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(category.color, in: RoundedRectangle(cornerRadius: 7))
                Text(category.title).font(.system(size: 13, weight: session.section == category ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(session.section == category ? Color.primary.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(session.section == category ? [.isSelected] : [])
    }
    private func settingsPage<Content: View>(_ category: CaptureSettingsSection, @ViewBuilder content: @escaping () -> Content) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(category.title).font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                content()
            }
            .padding(28).frame(maxWidth: 760, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .opacity(session.section == category ? 1 : 0)
        .allowsHitTesting(session.section == category)
        .disabled(session.section != category)
        .accessibilityHidden(session.section != category)
        .onChange(of: session.focusedShortcut) { action in
            if category == .shortcuts, let action { proxy.scrollTo(action, anchor: .center) }
        }
        .onChange(of: session.section) { target in
            if category == .shortcuts, target == category, let action = session.focusedShortcut { proxy.scrollTo(action, anchor: .center) }
        }
        }
    }
}

struct CaptureSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).accessibilityAddTraits(.isHeader) }
            VStack(alignment: .leading, spacing: 0, content: content)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct CaptureSettingsRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            content().labelsHidden().fixedSize(horizontal: true, vertical: false)
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 46)
    }
}

struct CaptureSettingsNote: View {
    let text: String
    var isError = false
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundColor(isError ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }
}

private struct CaptureGeneralSettingsPage: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var session: CaptureSettingsSession
    @ObservedObject private var workflow: CaptureWorkflowSettings
    @ObservedObject private var history: CaptureHistoryStore
    @ObservedObject var recognition: RecognitionSettings
    @State private var customLanguages = false
    @State private var message: String?
    @State private var failed = false
    init(model: CaptureLabViewModel, session: CaptureSettingsSession, recognition: RecognitionSettings) {
        self.model = model; self.session = session
        self.recognition = recognition
        workflow = model.workflowSettings; history = model.historyStore
    }
    var body: some View {
        CaptureSettingsGroup(title: L10n.text(en: "After Capture", zh: "截图完成后")) {
            CaptureSettingsRow(title: L10n.text(en: "Default action", zh: "默认操作"),
                               detail: L10n.text(en: "Screenshots are always copied and kept in history.", zh: "截图会自动复制，并保存在历史中。")) {
                Picker(L10n.text(en: "Default action", zh: "默认操作"), selection: $workflow.options.afterCapture) {
                    ForEach(CaptureAfterAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 150)
            }
        }
        CaptureSettingsGroup(title: L10n.text(en: "History", zh: "历史记录")) {
            CaptureSettingsRow(title: L10n.text(en: "Keep captures", zh: "保留数量")) {
                Picker(L10n.text(en: "Keep captures", zh: "保留数量"), selection: $session.retention.maximumCount) {
                    ForEach([30, 100, 300], id: \.self) { Text(L10n.text(en: "\($0) captures", zh: "\($0) 张")).tag($0) }
                }.frame(width: 150)
            }
            Divider().padding(.horizontal, 16)
            CaptureSettingsRow(title: L10n.text(en: "Remove older than", zh: "保留期限")) {
                Picker(L10n.text(en: "Remove older than", zh: "保留期限"), selection: Binding(
                    get: { session.retention.maximumAgeDays ?? 0 }, set: { session.retention.maximumAgeDays = $0 == 0 ? nil : $0 })) {
                    Text(L10n.text(en: "No time limit", zh: "不按时间清理")).tag(0)
                    ForEach([1, 7, 30], id: \.self) { Text(L10n.text(en: "\($0) days", zh: "\($0) 天")).tag($0) }
                }.frame(width: 150)
            }
            VStack(alignment: .leading, spacing: 12) {
                CaptureSettingsNote(text: L10n.text(en: "Review the affected captures before applying changes. Exported files are kept.", zh: "应用更改前会确认要清理的截图，已另存的文件会保留。"))
                if !history.recoveryProtectedIDs.isEmpty {
                    CaptureSettingsNote(text: L10n.text(en: "Recovered screenshots are protected until you review their retention.", zh: "恢复的截图暂不自动清理，应用保留设置时可确认处理。"))
                }
                if let message { CaptureSettingsNote(text: message, isError: failed) }
                Button(L10n.text(en: "Apply Retention", zh: "应用保留设置"), action: applyRetention)
                    .disabled(session.retention == history.retention && history.recoveryProtectedIDs.isEmpty)
            }.padding(16)
        }
        CaptureSettingsGroup(title: L10n.text(en: "Text Recognition", zh: "文字识别")) {
            CaptureSettingsRow(title: L10n.text(en: "Languages", zh: "识别语言")) {
                Picker(L10n.recognitionLanguages, selection: Binding(get: { languageChoice }, set: { chooseLanguage($0) })) {
                    Text(L10n.text(en: "Automatic", zh: "自动")).tag("auto")
                    Text(L10n.text(en: "Chinese & English", zh: "中英文")).tag("zh")
                    Text(L10n.text(en: "Japanese & English", zh: "日英文")).tag("ja")
                    Text(L10n.text(en: "Custom…", zh: "自选语言…")).tag("custom")
                }.frame(width: 150)
            }
            if customLanguages || languageChoice == "custom" {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recognition.supported, id: \.self) { language in
                        Toggle(Locale.current.localizedString(forIdentifier: language) ?? language, isOn: Binding(
                            get: { recognition.languages.contains(language) },
                            set: { value in recognition.select(value ? recognition.languages + [language] : recognition.languages.filter { $0 != language }) }))
                    }
                }.padding(16)
            }
            if let error = recognition.error { CaptureSettingsNote(text: error, isError: true).padding(16) }
        }
        .onAppear { model.refreshHistory(); session.synchronizeRetention(history.retention) }
        .onChange(of: history.retention) { session.synchronizeRetention($0) }
        .onChange(of: session.retention) { _ in message = nil }
    }
    private var languageChoice: String {
        if customLanguages { return "custom" }
        if recognition.languages.isEmpty { return "auto" }
        if Set(recognition.languages) == Set(["zh-Hans", "zh-Hant", "en-US"].filter(recognition.supported.contains)) { return "zh" }
        if Set(recognition.languages) == Set(["ja-JP", "en-US"].filter(recognition.supported.contains)) { return "ja" }
        return "custom"
    }
    private func chooseLanguage(_ value: String) {
        customLanguages = value == "custom"
        if value == "auto" { recognition.select([]) }
        if value == "zh" { recognition.select(["zh-Hans", "zh-Hant", "en-US"]) }
        if value == "ja" { recognition.select(["ja-JP", "en-US"]) }
    }
    private func applyRetention() {
        do {
            var preview = try history.previewRetention(session.retention)
            while true {
                if !preview.removingIDs.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = L10n.text(en: "Remove \(preview.removingIDs.count) captures?", zh: "清理 \(preview.removingIDs.count) 张历史截图？")
                    alert.informativeText = L10n.text(en: "Local history images and editable projects will be removed. Exported files are kept.", zh: "将删除相应的历史图片和可编辑项目，已另存的文件会保留。")
                    alert.addButton(withTitle: L10n.cancel); alert.addButton(withTitle: L10n.historyDelete)
                    guard alert.captureLabRunModal() == .alertSecondButtonReturn else { return }
                }
                if let changed = try history.applyRetention(preview) { preview = changed } else { break }
            }
            model.refreshHistory(); failed = false
            message = L10n.text(en: "Retention updated", zh: "保留设置已应用")
        } catch { failed = true; message = error.localizedDescription }
    }
}

private struct CaptureOverlaySettingsPage: View {
    @ObservedObject var model: CaptureLabViewModel
    @ObservedObject var session: CaptureSettingsSession
    @ObservedObject private var workflow: CaptureWorkflowSettings
    @State private var showsAppearance = false
    init(model: CaptureLabViewModel, session: CaptureSettingsSession) {
        self.model = model; self.session = session; workflow = model.workflowSettings
    }
    var body: some View {
        if workflow.options.afterCapture != .overlay {
            HStack {
                CaptureSettingsNote(text: L10n.text(en: "Quick Access is not your current after-capture action.", zh: "当前截图后操作未选择快捷浮层。"))
                Button(L10n.text(en: "General Settings", zh: "通用设置")) { session.navigate(to: .general) }
            }
        }
        CaptureSettingsGroup(title: L10n.text(en: "Display", zh: "显示")) {
            CaptureSettingsRow(title: L10n.text(en: "Position", zh: "位置")) {
                Picker(L10n.text(en: "Position", zh: "位置"), selection: $workflow.options.corner) {
                    ForEach(CaptureOverlayCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 150)
            }
            Divider().padding(.horizontal, 16)
            CaptureSettingsRow(title: L10n.text(en: "Follow capture display", zh: "跟随截图屏幕"),
                               detail: L10n.text(en: "Uses the main display when turned off.", zh: "关闭后显示在主屏幕。")) {
                Toggle(L10n.text(en: "Follow capture display", zh: "跟随截图屏幕"), isOn: $workflow.options.followsCaptureScreen).toggleStyle(.switch)
            }
        }
        CaptureSettingsGroup(title: L10n.text(en: "Behavior", zh: "行为")) {
            CaptureSettingsRow(title: L10n.text(en: "Auto-close", zh: "自动关闭"),
                               detail: L10n.text(en: "Pauses while hovering, dragging or capturing.", zh: "鼠标停留、拖动图片和截图期间暂停计时。")) {
                Picker(L10n.text(en: "Auto-close", zh: "自动关闭"), selection: $workflow.options.autoCloseSeconds) {
                    Text(L10n.text(en: "Never", zh: "不自动关闭")).tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { Text(L10n.text(en: "\($0) seconds", zh: "\($0) 秒")).tag($0) }
                }.frame(width: 150)
            }
        }
        DisclosureGroup(L10n.text(en: "Appearance", zh: "外观"), isExpanded: $showsAppearance) {
            CaptureSettingsGroup(title: "") {
                CaptureSettingsRow(title: L10n.text(en: "Preview size", zh: "预览大小")) {
                    Picker(L10n.text(en: "Preview size", zh: "预览大小"), selection: $workflow.options.overlayWidth) {
                        Text(L10n.text(en: "Compact", zh: "紧凑")).tag(280)
                        Text(L10n.text(en: "Standard", zh: "标准")).tag(320)
                        Text(L10n.text(en: "Large", zh: "较大")).tag(400)
                    }.frame(width: 150)
                }
            }.padding(.top, 10)
        }.font(.system(size: 13))
    }
}

struct CaptureUploadSettingsPage: View {
    @ObservedObject var draft: CaptureR2SettingsDraft
    var body: some View {
        CaptureSettingsGroup(title: "Cloudflare R2") {
            HStack(spacing: 7) {
                Image(systemName: draft.isDirty ? "pencil.circle" : draft.isConfigured ? "checkmark.circle.fill" : "icloud")
                Text(draft.isDirty ? L10n.text(en: "Unsaved changes", zh: "有未保存的更改") : draft.isConfigured
                     ? L10n.text(en: "Configured", zh: "已配置") : L10n.text(en: "Not configured", zh: "未配置"))
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Divider().padding(.horizontal, 16)
            field(L10n.r2Endpoint, placeholder: "https://<account-id>.r2.cloudflarestorage.com", text: $draft.endpoint)
            field(L10n.r2Bucket, placeholder: "captures", text: $draft.bucket)
            field(L10n.r2PathPrefix, placeholder: "captures", text: $draft.pathPrefix)
            field(L10n.r2PublicBaseURL, placeholder: "https://pub-xxxx.r2.dev", text: $draft.publicBaseURL, divider: false)
        }
        CaptureSettingsGroup(title: L10n.text(en: "Credentials", zh: "访问凭据")) {
            field(L10n.r2AccessKeyID, placeholder: "", text: $draft.accessKeyID)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.r2SecretAccessKey).font(.system(size: 13))
                SecureField(draft.canReuseStoredSecret ? L10n.r2KeepStoredSecret : "", text: $draft.secretAccessKey)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.r2SecretAccessKey)
                CaptureSettingsNote(text: draft.secretGuidance)
            }.padding(16)
        }
        if let message = draft.message { CaptureSettingsNote(text: message, isError: draft.failed) }
        HStack {
            CaptureSettingsNote(text: L10n.text(en: "The secret is stored securely in Keychain.", zh: "密钥安全保存在系统钥匙串中。"))
            Button(L10n.save) { draft.save() }.buttonStyle(.borderedProminent)
                .disabled(!draft.isDirty || !draft.canSave)
                .help(draft.saveGuidance).accessibilityHint(draft.saveGuidance)
        }
        if draft.isDirty && !draft.canSave { CaptureSettingsNote(text: draft.saveGuidance) }
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>, divider: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }.padding(16).overlay(alignment: .bottom) { if divider { Divider().padding(.horizontal, 16) } }
    }
}

private struct CaptureAboutSettingsPage: View {
    @ObservedObject var model: CaptureLabViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "viewfinder").font(.system(size: 44, weight: .light)).foregroundStyle(Color.accentColor)
            Text(L10n.appName).font(.system(size: 26, weight: .semibold))
            Text(L10n.text(en: "Screenshots, simply.", zh: "截图，简单一点。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            let version = CaptureLabViewModel.currentAppVersion
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
            Text(L10n.text(en: "Version \(version) (\(build))", zh: "版本 \(version)（\(build)）"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button(model.isCheckingForUpdates ? L10n.checkingForUpdates : L10n.checkForUpdates, action: model.checkForUpdates)
                .disabled(!model.canCheckForUpdates)
                .help(updateAvailability)
                .accessibilityHint(updateAvailability)
            if model.isCheckingForUpdates {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.checkingForUpdates).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if !model.canCheckForUpdates {
                CaptureSettingsNote(text: updateAvailability)
            }
        }.padding(.vertical, 16)
    }
    private var updateAvailability: String {
        if model.isCapturing { return L10n.text(en: "Available after the current screenshot finishes.", zh: "当前截图完成后即可使用。") }
        if model.isCheckingForUpdates { return L10n.checkingForUpdates }
        if !model.canCheckForUpdates { return L10n.text(en: "An update installation is pending. Finish the current screenshot to continue.", zh: "更新安装正在等待，当前截图完成后将继续。") }
        return L10n.text(en: "Check for a newer CaptureLab version.", zh: "检查 CaptureLab 是否有新版本。")
    }
}
