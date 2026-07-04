import Foundation

enum L10n {
    private enum Language {
        case english
        case chinese
    }

    private static var language: Language {
        let code = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return code.hasPrefix("zh") ? .chinese : .english
    }

    private static func text(en: String, zh: String) -> String {
        language == .chinese ? zh : en
    }

    static let appName = "CaptureLab"
    static var shortcutSettingsTitle: String { text(en: "Shortcut Settings", zh: "快捷键配置") }
    static var showCaptureLab: String { text(en: "Show CaptureLab", zh: "显示 CaptureLab") }
    static var captureRegion: String { text(en: "Capture Region", zh: "区域截图") }
    static var captureFullScreen: String { text(en: "Capture Full Screen", zh: "全屏截图") }
    static var captureWindow: String { text(en: "Capture Window", zh: "窗口截图") }
    static var captureDelayedMenu: String { text(en: "Delayed Capture", zh: "延迟截图") }
    static func captureDelayedRegion(_ seconds: Int) -> String {
        text(en: "Capture Region in \(seconds)s", zh: "\(seconds) 秒后区域截图")
    }
    static var openImage: String { text(en: "Open Image...", zh: "打开图片...") }
    static var saveEditedImage: String { text(en: "Save Edited Image...", zh: "保存编辑后图片...") }
    static var copyEditedImage: String { text(en: "Copy Edited Image", zh: "复制编辑后图片") }
    static var undoMarkup: String { text(en: "Undo Markup", zh: "撤销标注") }
    static var clearMarkups: String { text(en: "Clear Markups", zh: "清空标注") }
    static var captureMenu: String { text(en: "Capture", zh: "截图") }
    static var toolsMenu: String { text(en: "Tools", zh: "工具") }
    static var runOCR: String { text(en: "Run OCR", zh: "运行 OCR") }
    static var copyOCRText: String { text(en: "Copy OCR Text", zh: "复制 OCR 文本") }
    static var clearOCRText: String { text(en: "Clear OCR Text", zh: "清空 OCR 文本") }
    static var checkForUpdates: String { text(en: "Check for Updates...", zh: "检查更新...") }
    static var checkingForUpdates: String { text(en: "Checking for updates...", zh: "正在检查更新...") }
    static var quitCaptureLab: String { text(en: "Quit CaptureLab", zh: "退出 CaptureLab") }
    static var shortcutConfiguration: String { text(en: "Shortcut Settings...", zh: "快捷键配置...") }
    static var screenshotShortcut: String { text(en: "Screenshot shortcut", zh: "截图快捷键") }
    static var globalShortcutStatus: String { text(en: "Global shortcut", zh: "全局快捷键") }
    static func shortcutSummary(_ shortcut: String) -> String {
        text(en: "Screenshot shortcut: \(shortcut)", zh: "截图快捷键: \(shortcut)")
    }
    static func globalShortcutUnsupported(_ shortcut: String) -> String {
        text(en: "\(shortcut) is not supported as a global shortcut.", zh: "\(shortcut) 不支持作为全局快捷键。")
    }
    static func globalShortcutRegistrationFailed(_ shortcut: String) -> String {
        text(en: "Could not register \(shortcut). It may already be used by another app.", zh: "无法注册 \(shortcut)，可能已被其它应用占用。")
    }
    static var globalShortcutHandlerInstallFailed: String {
        text(en: "Could not install the global shortcut handler.", zh: "无法安装全局快捷键处理器。")
    }

    static var saveAs: String { text(en: "Save As", zh: "保存为") }
    static let done = "Done"
    static var copiedToClipboard: String { text(en: "Copied to clipboard", zh: "已复制到粘贴板") }
    static var zoom: String { text(en: "Zoom", zh: "缩放") }
    static var zoomFit: String { text(en: "Fit", zh: "适应") }
    static var copyImage: String { text(en: "Copy Image", zh: "复制图片") }
    static var savePNG: String { text(en: "Save PNG", zh: "保存 PNG") }
    static var upload: String { text(en: "Upload", zh: "上传") }
    static var uploadEditedImage: String { text(en: "Upload Edited Image", zh: "上传编辑后图片") }
    static var uploading: String { text(en: "Uploading...", zh: "正在上传...") }
    static var uploadedURLCopied: String { text(en: "Uploaded URL copied", zh: "已上传，URL 已复制") }
    static var uploadFailedTitle: String { text(en: "Upload Failed", zh: "上传失败") }
    static var recentCaptures: String { text(en: "Recent Captures", zh: "最近截图") }
    static var noRecentCaptures: String { text(en: "No recent captures", zh: "没有最近截图") }
    static var openRecentCapture: String { text(en: "Open", zh: "打开") }
    static var copyRecentCapture: String { text(en: "Copy", zh: "复制") }
    static var saveRecentCapture: String { text(en: "Save As...", zh: "另存为...") }
    static var uploadRecentCapture: String { text(en: "Upload", zh: "上传") }
    static var historyImageDataUnavailable: String { text(en: "Could not prepare the capture history image.", zh: "无法准备历史截图图片。") }
    static var historyImageNotFound: String { text(en: "The capture history image was not found.", zh: "找不到这张历史截图。") }
    static func historyMetadataLoadFailed(_ message: String) -> String {
        text(en: "Could not load capture history metadata: \(message)", zh: "无法加载截图历史元数据：\(message)")
    }
    static func captureCopiedButHistorySaveFailed(_ message: String) -> String {
        text(
            en: "Captured and copied, but history could not be saved: \(message)",
            zh: "已截图并复制，但无法保存到最近截图：\(message)"
        )
    }
    static var historyCaptureOpened: String { text(en: "Opened recent capture.", zh: "已打开最近截图。") }
    static var noOCRText: String { text(en: "No OCR text", zh: "没有 OCR 文本") }
    static var ocr: String { text(en: "OCR", zh: "OCR") }
    static var run: String { text(en: "Run", zh: "运行") }
    static var copy: String { text(en: "Copy", zh: "复制") }
    static var capture: String { text(en: "Capture", zh: "截图") }
    static func captureTitle(_ timestamp: String) -> String {
        text(en: "Capture \(timestamp)", zh: "截图 \(timestamp)")
    }
    static var open: String { text(en: "Open", zh: "打开") }

    static var shortcutSettingsSubtitle: String {
        text(en: "Set the global screenshot shortcut", zh: "设置全局截图快捷键")
    }
    static var shortcutHelp: String {
        text(en: "Press a shortcut containing ⌘, ⌃, or ⌥. Esc cancels.", zh: "请按下包含 ⌘、⌃ 或 ⌥ 的组合键。Esc 取消。")
    }
    static var recordingShortcut: String { text(en: "Recording", zh: "按键录入中") }
    static var cancel: String { text(en: "Cancel", zh: "取消") }
    static var save: String { text(en: "Save", zh: "保存") }

    static var ready: String { text(en: "Ready", zh: "就绪") }
    static var noImage: String { text(en: "No image", zh: "没有图片") }
    static var noMarkup: String { text(en: "No markup", zh: "没有标注") }
    static var oneMarkup: String { text(en: "1 markup", zh: "1 个标注") }
    static func markups(_ count: Int) -> String {
        text(en: "\(count) markups", zh: "\(count) 个标注")
    }
    static var selectRegionPrompt: String {
        text(en: "Select a region or press Esc to cancel.", zh: "选择区域，或按 Esc 取消。")
    }
    static var selectWindowPrompt: String {
        text(en: "Select a window or press Esc to cancel.", zh: "选择窗口，或按 Esc 取消。")
    }
    static var capturingFullScreen: String { text(en: "Capturing full screen...", zh: "正在截取全屏...") }
    static func selectDelayedRegionPrompt(_ seconds: Int) -> String {
        text(en: "Select a region. Capture starts after \(seconds) seconds.", zh: "选择区域，\(seconds) 秒后截图。")
    }
    static var capturedRegion: String { text(en: "Captured region.", zh: "已截图。") }
    static var capturedRegionAndCopied: String { text(en: "Captured region and copied.", zh: "已截图并复制到粘贴板。") }
    static var capturedFullScreen: String { text(en: "Captured full screen.", zh: "已截取全屏。") }
    static var capturedFullScreenAndCopied: String {
        text(en: "Captured full screen and copied.", zh: "已截取全屏并复制到粘贴板。")
    }
    static var capturedWindow: String { text(en: "Captured window.", zh: "已截取窗口。") }
    static var capturedWindowAndCopied: String {
        text(en: "Captured window and copied.", zh: "已截取窗口并复制到粘贴板。")
    }
    static func capturedDelayedRegion(_ seconds: Int) -> String {
        text(en: "Captured delayed region after \(seconds)s.", zh: "已完成 \(seconds) 秒延迟截图。")
    }
    static func capturedDelayedRegionAndCopied(_ seconds: Int) -> String {
        text(en: "Captured delayed region after \(seconds)s and copied.", zh: "已完成 \(seconds) 秒延迟截图并复制到粘贴板。")
    }
    static func opened(_ name: String) -> String { text(en: "Opened \(name).", zh: "已打开 \(name)。") }
    static var imageCopied: String { text(en: "Image copied.", zh: "图片已复制。") }
    static var imageCopyFailed: String { text(en: "Could not copy image.", zh: "无法复制图片。") }
    static func saved(_ name: String) -> String { text(en: "Saved \(name).", zh: "已保存 \(name)。") }
    static var recognizingText: String { text(en: "Recognizing text...", zh: "正在识别文字...") }
    static var noTextFound: String { text(en: "No text found.", zh: "未找到文字。") }
    static func recognizedLines(_ count: Int) -> String {
        text(en: "Recognized \(count) line(s).", zh: "已识别 \(count) 行。")
    }
    static var ocrTextCopied: String { text(en: "OCR text copied.", zh: "OCR 文本已复制。") }
    static var ocrTextCleared: String { text(en: "OCR text cleared.", zh: "OCR 文本已清空。") }
    static func annotationAdded(_ title: String) -> String {
        text(en: "\(title) added.", zh: "已添加\(title)。")
    }
    static var markupUndone: String { text(en: "Markup undone.", zh: "已撤销标注。") }
    static var markupCleared: String { text(en: "Markup cleared.", zh: "标注已清空。") }
    static var saveCaptureTitle: String { text(en: "Save Capture", zh: "保存截图") }
    static var openImageTitle: String { text(en: "Open Image", zh: "打开图片") }

    static var captureCancelled: String { text(en: "Capture cancelled.", zh: "截图已取消。") }
    static var imageLoadFailed: String { text(en: "Could not load the image.", zh: "无法加载图片。") }
    static var imageExportFailed: String { text(en: "Could not export the image.", zh: "无法导出图片。") }
    static var ocrImageUnavailable: String { text(en: "Could not prepare this image for OCR.", zh: "无法准备图片进行 OCR。") }
    static var noCaptureFileCreated: String { text(en: "No capture file was created.", zh: "没有生成截图文件。") }

    static var toolSelect: String { text(en: "Select", zh: "选择") }
    static var toolArrow: String { text(en: "Arrow", zh: "箭头") }
    static var toolLine: String { text(en: "Line", zh: "直线") }
    static var toolBox: String { text(en: "Box", zh: "矩形") }
    static var toolCounter: String { text(en: "Counter", zh: "计数器") }
    static var toolBrush: String { text(en: "Brush", zh: "画笔") }
    static var toolText: String { text(en: "Text", zh: "文字") }
    static var toolTextHighlight: String { text(en: "Text Highlight", zh: "文字高亮") }
    static var toolMosaic: String { text(en: "Mosaic", zh: "马赛克") }
    static var defaultAnnotationText: String { text(en: "Text", zh: "文字") }

    static var updateAvailableTitle: String { text(en: "Update Available", zh: "发现新版本") }
    static func updateAvailableMessage(current: String, latest: String) -> String {
        text(
            en: "CaptureLab \(latest) is available. Current version: \(current). CaptureLab can download, verify, install, and relaunch automatically.",
            zh: "CaptureLab \(latest) 已发布。当前版本：\(current)。CaptureLab 可以自动下载、校验、安装并重启。"
        )
    }
    static var installUpdate: String { text(en: "Install Update", zh: "安装更新") }
    static func downloadingUpdate(_ version: String) -> String {
        text(en: "Downloading CaptureLab \(version)...", zh: "正在下载 CaptureLab \(version)...")
    }
    static var installingUpdate: String {
        text(en: "Installing update and relaunching...", zh: "正在安装更新并重启...")
    }
    static var later: String { text(en: "Later", zh: "稍后") }
    static var upToDateTitle: String { text(en: "CaptureLab is up to date", zh: "CaptureLab 已是最新版本") }
    static func upToDateMessage(current: String) -> String {
        text(en: "Current version: \(current).", zh: "当前版本：\(current)。")
    }
    static var updateCheckFailedTitle: String { text(en: "Could not check for updates", zh: "无法检查更新") }
    static var updateRepositoryUnavailable: String {
        text(
            en: "No public release was found for https://github.com/MoarLiu/CaptureLab.",
            zh: "没有在 https://github.com/MoarLiu/CaptureLab 找到公开发布版本。"
        )
    }
    static func updateAssetUnavailable(_ architecture: String) -> String {
        text(
            en: "No downloadable CaptureLab update was found for \(architecture).",
            zh: "没有找到适用于 \(architecture) 的 CaptureLab 可下载更新。"
        )
    }
    static var updateDownloadFailed: String {
        text(en: "Could not download the update.", zh: "无法下载更新。")
    }
    static var updateChecksumMismatch: String {
        text(en: "The downloaded update did not pass checksum verification.", zh: "下载的更新未通过校验。")
    }
    static func updateInstallFailed(_ message: String) -> String {
        text(en: "Could not install the update: \(message)", zh: "无法安装更新：\(message)")
    }
    static var ok: String { text(en: "OK", zh: "确定") }

    static var cloudflareR2SettingsTitle: String { text(en: "Cloudflare R2 Settings", zh: "Cloudflare R2 设置") }
    static var cloudflareR2SettingsMenuItem: String { text(en: "Cloudflare R2 Settings...", zh: "Cloudflare R2 设置...") }
    static var r2Endpoint: String { text(en: "Endpoint", zh: "Endpoint") }
    static var r2Bucket: String { text(en: "Bucket", zh: "Bucket") }
    static var r2PathPrefix: String { text(en: "Path Prefix", zh: "路径前缀") }
    static var r2PublicBaseURL: String { text(en: "Public Base URL", zh: "公开 URL 前缀") }
    static var r2AccessKeyID: String { text(en: "Access Key ID", zh: "Access Key ID") }
    static var r2SecretAccessKey: String { text(en: "Secret Access Key", zh: "Secret Access Key") }
    static var r2KeepStoredSecret: String { text(en: "Leave blank to keep stored secret", zh: "留空则保留已保存密钥") }
    static var r2SettingsSaved: String { text(en: "Cloudflare R2 settings saved.", zh: "Cloudflare R2 设置已保存。") }
    static var r2SettingsNotConfigured: String {
        text(en: "Cloudflare R2 is not configured.", zh: "Cloudflare R2 尚未配置。")
    }
    static func r2SettingsLoadFailed(_ message: String) -> String {
        text(en: "Could not load Cloudflare R2 settings: \(message)", zh: "无法加载 Cloudflare R2 设置：\(message)")
    }
    static func r2IncompleteField(_ field: String) -> String {
        text(en: "\(field) is required.", zh: "\(field) 为必填项。")
    }
    static func r2InvalidURL(_ field: String) -> String {
        text(en: "\(field) must be a valid URL.", zh: "\(field) 必须是有效 URL。")
    }
    static func r2FileTooLarge(_ limit: Int) -> String {
        text(en: "The image is larger than \(limit) bytes.", zh: "图片超过 \(limit) 字节限制。")
    }
    static var r2UploadNoHTTPResponse: String {
        text(en: "Cloudflare R2 upload failed without an HTTP response.", zh: "Cloudflare R2 上传没有返回 HTTP 响应。")
    }
    static var r2UploadBadRequest: String {
        text(en: "Cloudflare R2 rejected the request. Check the endpoint, bucket, and path prefix.", zh: "Cloudflare R2 拒绝了请求。请检查 Endpoint、Bucket 和路径前缀。")
    }
    static func r2UploadForbidden(_ statusCode: Int) -> String {
        text(en: "Cloudflare R2 rejected the credentials or permissions (HTTP \(statusCode)).", zh: "Cloudflare R2 拒绝了凭据或权限 (HTTP \(statusCode))。")
    }
    static var r2UploadNotFound: String {
        text(en: "Cloudflare R2 target was not found. Check the endpoint and bucket.", zh: "未找到 Cloudflare R2 目标。请检查 Endpoint 和 Bucket。")
    }
    static func r2UploadRateLimited(_ statusCode: Int) -> String {
        text(en: "Cloudflare R2 timed out or rate-limited the upload (HTTP \(statusCode)).", zh: "Cloudflare R2 上传超时或触发限流 (HTTP \(statusCode))。")
    }
    static var r2UploadTooLarge: String {
        text(en: "Cloudflare R2 refused the image because it is too large.", zh: "Cloudflare R2 因图片过大拒绝上传。")
    }
    static func r2UploadServerError(_ statusCode: Int) -> String {
        text(en: "Cloudflare R2 is temporarily unavailable (HTTP \(statusCode)).", zh: "Cloudflare R2 暂时不可用 (HTTP \(statusCode))。")
    }
    static func r2UploadHTTPError(_ statusCode: Int) -> String {
        text(en: "Cloudflare R2 upload failed with HTTP \(statusCode).", zh: "Cloudflare R2 上传失败，HTTP \(statusCode)。")
    }
    static var r2UploadOffline: String {
        text(en: "This Mac is offline.", zh: "当前 Mac 未联网。")
    }
    static var r2UploadTimedOut: String {
        text(en: "Cloudflare R2 upload timed out.", zh: "Cloudflare R2 上传超时。")
    }
    static var r2UploadCannotResolveHost: String {
        text(en: "Could not resolve the Cloudflare R2 endpoint.", zh: "无法解析 Cloudflare R2 Endpoint。")
    }
    static var r2UploadConnectionLost: String {
        text(en: "The connection to Cloudflare R2 was interrupted.", zh: "Cloudflare R2 连接中断。")
    }
    static func r2UploadNetworkError(_ message: String) -> String {
        text(en: "Cloudflare R2 upload failed: \(message)", zh: "Cloudflare R2 上传失败：\(message)")
    }
}
