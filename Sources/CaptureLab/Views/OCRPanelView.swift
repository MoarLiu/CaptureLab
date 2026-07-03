import SwiftUI

struct CaptureInspectorView: View {
    @ObservedObject var model: CaptureLabViewModel
    @State private var selectedSection: InspectorSection = .details

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker(L10n.inspector, selection: $selectedSection) {
                ForEach(InspectorSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch selectedSection {
            case .ocr:
                ocrSection
            case .details:
                detailsSection
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(L10n.inspector)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.isRecognizingText {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    private var ocrSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MetricPill(title: "\(model.ocrLineCount)", subtitle: L10n.lines, color: .green)
                MetricPill(title: "\(model.ocrText.count)", subtitle: L10n.chars, color: .blue)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Button {
                    model.recognizeText()
                } label: {
                    Label(L10n.runOCR, systemImage: "text.viewfinder")
                }
                .buttonStyle(InspectorActionButtonStyle())
                .disabled(!model.hasImage || model.isRecognizingText)

                Button {
                    model.copyOCRText()
                } label: {
                    Label(L10n.copy, systemImage: "doc.on.doc")
                }
                .buttonStyle(InspectorActionButtonStyle())
                .disabled(model.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    model.clearOCRText()
                } label: {
                    Image(systemName: "xmark.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(InspectorIconButtonStyle())
                .help(L10n.clearOCRText)
                .disabled(model.ocrText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.ocrText)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .disabled(model.isRecognizingText)

                if model.ocrText.isEmpty && !model.isRecognizingText {
                    Text(L10n.noText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var detailsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorGroup(title: L10n.capture) {
                    DetailRow(title: L10n.name, value: model.documentTitle)
                    DetailRow(title: L10n.size, value: model.imageDimensionsTitle)
                    DetailRow(title: L10n.markup, value: model.annotationCountTitle)
                    DetailRow(title: L10n.ocr, value: "\(model.ocrLineCount) \(L10n.lines)")
                }

                InspectorGroup(title: L10n.output) {
                    Button {
                        model.copyRenderedImage()
                    } label: {
                        Label(L10n.copyImage, systemImage: "doc.on.doc")
                    }
                    .buttonStyle(InspectorWideButtonStyle())
                    .disabled(!model.hasImage)

                    Button {
                        model.saveRenderedImage()
                    } label: {
                        Label(L10n.savePNG, systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(InspectorWideButtonStyle())
                    .disabled(!model.hasImage)
                }

                InspectorGroup(title: L10n.cleanup) {
                    Button {
                        model.undoAnnotation()
                    } label: {
                        Label(L10n.undoMarkup, systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(InspectorWideButtonStyle())
                    .disabled(!model.canUndoAnnotation)

                    Button {
                        model.clearDocument()
                    } label: {
                        Label(L10n.clearCapture, systemImage: "xmark.rectangle")
                    }
                    .buttonStyle(InspectorWideButtonStyle(tint: .red))
                    .disabled(!model.hasImage)
                }
            }
            .padding(12)
        }
    }
}

private enum InspectorSection: String, CaseIterable, Identifiable {
    case details
    case ocr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ocr:
            return L10n.ocr
        case .details:
            return L10n.info
        }
    }

    var systemImage: String {
        switch self {
        case .ocr:
            return "text.viewfinder"
        case .details:
            return "info.circle"
        }
    }
}

private struct MetricPill: View {
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 42, alignment: .leading)
        .frame(minWidth: 72, alignment: .leading)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

private struct InspectorActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct InspectorIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct InspectorWideButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(configuration.isPressed ? tint.opacity(0.1) : Color.clear)
    }
}
