import AppKit
import SwiftUI

enum CaptureSettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, overlay, upload, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L10n.text(en: "General", zh: "通用")
        case .shortcuts: return L10n.text(en: "Shortcuts", zh: "快捷键")
        case .overlay: return L10n.text(en: "Quick Access", zh: "快捷浮层")
        case .upload: return L10n.text(en: "Uploads", zh: "上传")
        case .about: return L10n.text(en: "About", zh: "关于")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .overlay: return "rectangle.on.rectangle"
        case .upload: return "icloud.fill"
        case .about: return "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .shortcuts: return .indigo
        case .overlay: return .green
        case .upload: return .blue
        case .about: return .gray
        }
    }
}

/// Keeps uncommitted credentials in memory across category changes. The store
/// remains the sole owner of Keychain access and its transactional save rules.
@MainActor
final class CaptureR2SettingsDraft: ObservableObject {
    @Published var endpoint = ""
    @Published var bucket = ""
    @Published var pathPrefix = "captures"
    @Published var publicBaseURL = ""
    @Published var accessKeyID = ""
    @Published var secretAccessKey = ""
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    private let store: CloudflareR2SettingsStore
    private var baseline: CloudflareR2SettingsInput?

    init(store: CloudflareR2SettingsStore) { self.store = store; reload() }

    var input: CloudflareR2SettingsInput {
        .init(endpoint: endpoint, bucket: bucket, pathPrefix: pathPrefix, publicBaseURL: publicBaseURL,
              accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
    }
    var isDirty: Bool {
        guard let baseline else { return false }
        let value = input
        return value.endpoint != baseline.endpoint || value.bucket != baseline.bucket
            || value.pathPrefix != baseline.pathPrefix || value.publicBaseURL != baseline.publicBaseURL
            || value.accessKeyID != baseline.accessKeyID || !secretAccessKey.isEmpty
    }
    var isConfigured: Bool { store.settings != nil && store.loadError == nil }
    var canReuseStoredSecret: Bool {
        let key = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.settings?.accessKeyID == key && !(store.settings?.secretAccessKey.isEmpty ?? true)
    }
    var secretGuidance: String {
        canReuseStoredSecret ? L10n.r2KeepStoredSecret
            : L10n.text(en: "Enter the secret for this Access Key ID. A different key cannot reuse the stored secret.",
                        zh: "请输入此 Access Key ID 对应的密钥。更换 ID 后不能沿用原密钥。")
    }
    var saveGuidance: String {
        if !isDirty { return L10n.text(en: "No unsaved changes.", zh: "没有未保存的更改。") }
        if !canSave { return L10n.text(en: "Complete the connection fields and credentials to save.", zh: "填写完整的连接信息和访问凭据后即可保存。") }
        return L10n.text(en: "Save these upload settings.", zh: "保存当前上传设置。")
    }
    var canSave: Bool {
        let key = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        return [endpoint, bucket, pathPrefix, publicBaseURL, key].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (!secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || canReuseStoredSecret)
    }
    func reload() {
        let value = store.settings
        endpoint = value?.endpoint ?? ""; bucket = value?.bucket ?? ""
        pathPrefix = value?.pathPrefix ?? "captures"; publicBaseURL = value?.publicBaseURL ?? ""
        accessKeyID = value?.accessKeyID ?? ""; secretAccessKey = ""
        baseline = input
        failed = store.loadError != nil; message = store.loadError?.localizedDescription
    }
    @discardableResult func save() -> Bool {
        do {
            try store.save(input)
            reload()
            failed = false; message = L10n.r2SettingsSaved
            return true
        } catch {
            failed = true; message = error.localizedDescription
            return false
        }
    }
}

@MainActor
final class CaptureSettingsSession: ObservableObject {
    @Published var section = CaptureSettingsSection.general {
        didSet { if section != oldValue { recordingAction = nil } }
    }
    @Published var recordingAction: CaptureAction?
    @Published var focusedShortcut: CaptureAction?
    @Published var retention: CaptureHistoryRetention
    private var appliedRetention: CaptureHistoryRetention
    let upload: CaptureR2SettingsDraft

    init(store: CloudflareR2SettingsStore, retention: CaptureHistoryRetention) {
        upload = CaptureR2SettingsDraft(store: store)
        self.retention = retention
        self.appliedRetention = retention
    }
    func synchronizeRetention(_ value: CaptureHistoryRetention) {
        if retention == appliedRetention { retention = value }
        appliedRetention = value
    }
    func navigate(to section: CaptureSettingsSection?, shortcut: CaptureAction? = nil) {
        recordingAction = nil
        if let section { self.section = section }
        focusedShortcut = shortcut
    }
    func prepareForClose() -> Bool {
        recordingAction = nil
        guard upload.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.text(en: "Save upload settings?", zh: "保存上传设置？")
        alert.informativeText = L10n.text(en: "Your upload settings have unsaved changes.", zh: "上传设置还有尚未保存的更改。")
        alert.addButton(withTitle: L10n.save)
        alert.addButton(withTitle: L10n.cancel)
        alert.addButton(withTitle: L10n.text(en: "Discard Changes", zh: "放弃更改"))
        switch alert.captureLabRunModal() {
        case .alertFirstButtonReturn:
            if upload.save() { return true }
            section = .upload
            return false
        case .alertThirdButtonReturn: upload.reload(); return true
        default: return false
        }
    }
}

struct CaptureSettingsCloseGuard: NSViewRepresentable {
    let session: CaptureSettingsSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> CaptureDocumentCloseGuard.AttachmentView {
        let view = CaptureDocumentCloseGuard.AttachmentView()
        view.attach = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: CaptureDocumentCloseGuard.AttachmentView, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: CaptureDocumentCloseGuard.AttachmentView, coordinator: Coordinator) { coordinator.detach() }
    private struct DelegateReference: @unchecked Sendable { let value: (any NSWindowDelegate)? }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private let session: CaptureSettingsSession
        private weak var window: NSWindow?
        private weak var original: (any NSWindowDelegate)?
        init(session: CaptureSettingsSession) { self.session = session }
        func attach(_ window: NSWindow?) {
            guard let window, self.window !== window || window.delegate !== self else { return }
            detach(); self.window = window; original = window.delegate; window.delegate = self
        }
        func detach() {
            if window?.delegate === self { window?.delegate = original }
            window = nil; original = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            session.prepareForClose() && (original?.windowShouldClose?(sender) ?? true)
        }
        func windowDidResignKey(_ notification: Notification) {
            session.recordingAction = nil
            original?.windowDidResignKey?(notification)
        }
        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { original?.responds(to: selector) ?? false }
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            guard Thread.isMainThread else { return nil }
            return MainActor.assumeIsolated { DelegateReference(value: original) }.value
        }
    }
}
