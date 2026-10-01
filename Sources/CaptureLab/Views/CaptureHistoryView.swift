import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CaptureHistoryView: View {
    @ObservedObject var model: CaptureLabViewModel
    let showEditor: () -> Void

    @State private var pendingDeletion: CaptureHistoryItem?
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.historyBrowserTitle)
                    .font(.title2.bold())
                Text("\(model.historyItems.count) / \(CaptureHistoryStore.maxItemCount)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshHistory()
                } label: {
                    Label(L10n.historyRefresh, systemImage: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            if model.historyItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                    Text(L10n.noRecentCaptures)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.historyItems) { item in
                            historyCard(item)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { model.refreshHistory() }
        .alert(
            L10n.historyDeleteConfirmationTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { item in
            Button(L10n.cancel, role: .cancel) { pendingDeletion = nil }
            Button(L10n.historyDelete, role: .destructive) {
                model.deleteHistoryItem(item)
                pendingDeletion = nil
            }
        } message: { _ in
            Text(L10n.historyDeleteConfirmationMessage)
        }
    }

    private func historyCard(_ item: CaptureHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                open(item)
            } label: {
                CaptureHistoryThumbnailView(
                    url: model.historyURL(for: item),
                    revision: model.historyRevision
                )
                .frame(height: 145)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(L10n.openRecentCapture)
            .disabled(model.isCapturing)

            Text(item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack {
                Text("\(item.pixelWidth) × \(item.pixelHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.copyHistoryItem(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(L10n.copyRecentCapture)
                Button {
                    model.pinHistoryItem(item)
                } label: {
                    Image(systemName: "pin")
                }
                .help(L10n.historyPin)
                Menu {
                    actions(for: item)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(item.displayTitle)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .contextMenu { actions(for: item) }
    }

    @ViewBuilder
    private func actions(for item: CaptureHistoryItem) -> some View {
        Button(L10n.openRecentCapture) { open(item) }
            .disabled(model.isCapturing)
        Button(L10n.copyRecentCapture) { model.copyHistoryItem(item) }
        Button(L10n.saveRecentCapture) { model.saveHistoryItem(item) }
        Button(L10n.uploadRecentCapture) { model.uploadHistoryItem(item) }
            .disabled(model.isUploading)
        Button(L10n.historyPin) { model.pinHistoryItem(item) }
        Divider()
        Button(L10n.historyDelete, role: .destructive) { pendingDeletion = item }
    }

    private func open(_ item: CaptureHistoryItem) {
        showEditor()
        model.openHistoryItem(item)
    }
}

@MainActor
private struct CaptureHistoryThumbnailView: View {
    let url: URL
    let revision: UUID
    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    private struct Identity: Hashable {
        var url: URL
        var revision: UUID
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(6)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(L10n.historyThumbnailUnavailable, systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: Identity(url: url, revision: revision)) {
            thumbnail = nil
            isLoading = true
            let imageURL = url
            let worker = Task.detached(priority: .utility) {
                Self.thumbnailData(at: imageURL)
            }
            let data = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap(NSImage.init(data:))
            isLoading = false
        }
    }

    /// Decode only a small preview and transfer immutable encoded data back to
    /// the main actor. Large originals are never retained by the history grid.
    private nonisolated static func thumbnailData(at url: URL) -> Data? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              !Task.isCancelled else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !Task.isCancelled else { return nil }
        return data as Data
    }
}
