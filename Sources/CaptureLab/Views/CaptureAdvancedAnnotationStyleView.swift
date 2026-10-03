import AppKit
import SwiftUI

struct CaptureAnnotationStylePreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var appearance: CaptureAnnotationAppearance
}

/// All edits go through the caller's binding, preserving its undo transaction.
struct CaptureAdvancedAnnotationStyleView: View {
    @Binding var appearance: CaptureAnnotationAppearance
    let tool: CaptureTool
    var highlightAlignmentAction: (() -> Void)?
    @AppStorage("annotation.favoriteColors") private var favoriteData = Data()
    @AppStorage("annotation.savedStyles") private var styleData = Data()
    @State private var presetName = ""

    private var favorites: [CaptureAnnotationColor] {
        (try? JSONDecoder().decode([CaptureAnnotationColor].self, from: favoriteData)) ?? []
    }
    private var presets: [CaptureAnnotationStylePreset] {
        ((try? JSONDecoder().decode([CaptureAnnotationStylePreset].self, from: styleData)) ?? [])
            .filter { $0.appearance.isValid }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tool == .arrow || tool == .curvedArrow {
                Picker(L10n.text(en: "Arrow", zh: "箭头样式"), selection: value(\.arrowStyle, fallback: .open)) {
                    ForEach(CaptureArrowStyle.allCases) { Text($0.title).tag($0) }
                }
            }
            if [.rectangle, .ellipse, .filledRectangle].contains(tool) {
                Picker(L10n.text(en: "Shape", zh: "形状样式"), selection: value(\.shapeFill, fallback: tool == .filledRectangle ? .fill : .stroke)) {
                    ForEach(CaptureShapeFill.allCases) { Text($0.title).tag($0) }
                }
                ColorPicker(L10n.text(en: "Fill color", zh: "填充颜色"), selection: color(\.fillColor, fallback: .systemRed), supportsOpacity: false)
            }
            if tool == .text { textStyle }
            if tool == .blur {
                slider(L10n.text(en: "Blur radius", zh: "模糊强度"), binding: value(\.blurRadius, fallback: 12), range: 1...60)
                Text(L10n.text(en: "Blur is a visual effect. Use mosaic to redact sensitive content.", zh: "模糊用于视觉处理；遮挡敏感内容请使用马赛克。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if tool == .spotlight {
                slider(L10n.text(en: "Dimming", zh: "周围暗度"), binding: value(\.spotlightOpacity, fallback: 0.6), range: 0.05...0.95)
            }
            if tool == .brush {
                slider(L10n.text(en: "Smoothing", zh: "笔迹平滑"), binding: value(\.brushSmoothing, fallback: 0.65), range: 0...1)
            }
            if tool == .highlight {
                Toggle(L10n.text(en: "Align to recognized text", zh: "辅助对齐文字区域"), isOn: value(\.highlightTextAlignment, fallback: false))
                if let highlightAlignmentAction {
                    Button(L10n.text(en: "Detect text regions", zh: "检测文字区域"), action: highlightAlignmentAction)
                }
                Text(L10n.text(en: "Drag to highlight a line; resize handles remain available for manual adjustment.", zh: "拖动高亮时辅助对齐单行文字；仍可拖动边框手动调整。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(L10n.text(en: "Favorite colors", zh: "常用颜色")).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(27)), count: 8), alignment: .leading) {
                ForEach(Array(favorites.enumerated()), id: \.offset) { entry in
                    Button { appearance.color = entry.element } label: {
                        Circle().fill(Color(nsColor: entry.element.nsColor)).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(en: "Favorite color \(entry.offset + 1)", zh: "常用颜色 \(entry.offset + 1)"))
                    .contextMenu {
                        Button(L10n.text(en: "Remove", zh: "移除")) {
                            var updated = favorites; updated.remove(at: entry.offset)
                            favoriteData = (try? JSONEncoder().encode(updated)) ?? Data()
                        }
                    }
                }
            }
            Button(L10n.text(en: "Save current color", zh: "收藏当前颜色")) {
                let current = appearance.color ?? CaptureAnnotationColor(tool == .highlight ? .systemYellow : .systemRed)
                guard !favorites.contains(current), favorites.count < 24 else { return }
                favoriteData = (try? JSONEncoder().encode(favorites + [current])) ?? Data()
            }.disabled(favorites.count >= 24)
            Divider()
            Text(L10n.text(en: "Reusable styles", zh: "可复用样式")).font(.headline)
            HStack {
                TextField(L10n.text(en: "Style name", zh: "样式名称"), text: $presetName)
                Button(L10n.text(en: "Save", zh: "保存")) {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, appearance.isValid else { return }
                    var updated = presets.filter { $0.name != name }
                    updated.append(CaptureAnnotationStylePreset(name: String(name.prefix(80)), appearance: appearance))
                    styleData = (try? JSONEncoder().encode(Array(updated.suffix(30)))) ?? Data()
                    presetName = ""
                }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !presets.isEmpty {
                HStack {
                    Menu(L10n.text(en: "Apply saved style", zh: "应用已存样式")) {
                        ForEach(presets) { preset in Button(preset.name) { appearance = preset.appearance } }
                    }
                    Menu(L10n.text(en: "Delete style", zh: "删除样式")) {
                        ForEach(presets) { preset in
                            Button(preset.name) { styleData = (try? JSONEncoder().encode(presets.filter { $0.id != preset.id })) ?? Data() }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var textStyle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text(en: "Font", zh: "字体"), selection: value(\.fontFamily, fallback: "")) {
                Text(L10n.text(en: "System", zh: "系统字体")).tag("")
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker(L10n.text(en: "Weight", zh: "字重"), selection: value(\.fontWeight, fallback: .semibold)) {
                ForEach(CaptureFontWeight.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text(en: "Alignment", zh: "对齐"), selection: value(\.textAlignment, fallback: .center)) {
                ForEach(CaptureTextAlignment.allCases) { Text($0.title).tag($0) }
            }
            Toggle(L10n.text(en: "Text background", zh: "文字背景"), isOn: enabled(\.textBackgroundColor, fallback: .white))
            if appearance.textBackgroundColor != nil {
                ColorPicker(L10n.text(en: "Background color", zh: "背景颜色"), selection: color(\.textBackgroundColor, fallback: .white), supportsOpacity: false)
            }
            Toggle(L10n.text(en: "Text border", zh: "文字边框"), isOn: enabled(\.textBorderColor, fallback: .black))
            if appearance.textBorderColor != nil {
                ColorPicker(L10n.text(en: "Border color", zh: "边框颜色"), selection: color(\.textBorderColor, fallback: .black), supportsOpacity: false)
            }
        }
    }
    private func value<T>(_ key: WritableKeyPath<CaptureAnnotationAppearance, T?>, fallback: T) -> Binding<T> {
        Binding(get: { appearance[keyPath: key] ?? fallback }, set: { appearance[keyPath: key] = $0 })
    }
    private func color(_ key: WritableKeyPath<CaptureAnnotationAppearance, CaptureAnnotationColor?>, fallback: NSColor) -> Binding<Color> {
        Binding(get: { Color(nsColor: appearance[keyPath: key]?.nsColor ?? fallback) }, set: { appearance[keyPath: key] = CaptureAnnotationColor(NSColor($0)) })
    }
    private func enabled(_ key: WritableKeyPath<CaptureAnnotationAppearance, CaptureAnnotationColor?>, fallback: NSColor) -> Binding<Bool> {
        Binding(get: { appearance[keyPath: key] != nil }, set: { appearance[keyPath: key] = $0 ? CaptureAnnotationColor(fallback) : nil })
    }
    private func slider(_ title: String, binding: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Slider(value: binding, in: range).accessibilityLabel(title)
        }
    }
}
