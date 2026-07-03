import SwiftUI

struct CaptureCanvasView: View {
    let document: CaptureDocument?
    @Binding var annotations: [CaptureAnnotation]
    @Binding var selectedTool: CaptureTool
    let captureAction: () -> Void
    let openAction: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CanvasBackdropView()

                if let document {
                    CaptureAnnotationCanvasView(
                        document: document,
                        annotations: $annotations,
                        selectedTool: $selectedTool
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    emptyState
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "viewfinder")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 62, height: 62)

            Text(L10n.appName)
                .font(.system(size: 18, weight: .semibold))

            HStack(spacing: 10) {
                Button {
                    captureAction()
                } label: {
                    Label(L10n.capture, systemImage: "viewfinder")
                }
                .buttonStyle(CaptureCanvasActionButtonStyle(isPrimary: true))

                Button {
                    openAction()
                } label: {
                    Label(L10n.open, systemImage: "photo")
                }
                .buttonStyle(CaptureCanvasActionButtonStyle(isPrimary: false))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CanvasBackdropView: View {
    var body: some View {
        Color(nsColor: .textBackgroundColor)
    }
}

private struct CaptureCanvasActionButtonStyle: ButtonStyle {
    var isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isPrimary ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPrimary {
            return Color.accentColor.opacity(isPressed ? 0.82 : 1)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(isPressed ? 0.72 : 0.94)
    }
}
