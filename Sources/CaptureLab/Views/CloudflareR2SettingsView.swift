import AppKit
import SwiftUI

struct CloudflareR2SettingsView: View {
    @ObservedObject var store: CloudflareR2SettingsStore

    @State private var endpoint = ""
    @State private var bucket = ""
    @State private var pathPrefix = "captures"
    @State private var publicBaseURL = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.cloudflareR2SettingsTitle)
                    .font(.system(size: 20, weight: .semibold))

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    settingsRow(L10n.r2Endpoint) {
                        TextField("https://<account-id>.r2.cloudflarestorage.com", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsRow(L10n.r2Bucket) {
                        TextField("captures", text: $bucket)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsRow(L10n.r2PathPrefix) {
                        TextField("captures", text: $pathPrefix)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsRow(L10n.r2PublicBaseURL) {
                        TextField("https://pub-xxxx.r2.dev", text: $publicBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsRow(L10n.r2AccessKeyID) {
                        TextField("", text: $accessKeyID)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsRow(L10n.r2SecretAccessKey) {
                        SecureField(store.settings == nil ? "" : L10n.r2KeepStoredSecret, text: $secretAccessKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(22)

            Divider()

            HStack(spacing: 12) {
                Text(statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(L10n.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadIfNeeded)
        .captureLabWindowCloseShortcuts()
    }

    private var canSave: Bool {
        let trimmedAccessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let canReuseStoredSecret = store.settings?.accessKeyID == trimmedAccessKeyID
            && !(store.settings?.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        return !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trimmedAccessKeyID.isEmpty
            && (!secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || canReuseStoredSecret)
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .trailing)

            content()
                .frame(width: 360)
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else {
            return
        }
        didLoad = true
        if let loadError = store.loadError {
            statusIsError = true
            statusMessage = loadError.localizedDescription
        }
        guard let settings = store.settings else {
            return
        }
        endpoint = settings.endpoint
        bucket = settings.bucket
        pathPrefix = settings.pathPrefix
        publicBaseURL = settings.publicBaseURL
        accessKeyID = settings.accessKeyID
        secretAccessKey = ""
    }

    private func save() {
        do {
            try store.save(CloudflareR2SettingsInput(
                endpoint: endpoint,
                bucket: bucket,
                pathPrefix: pathPrefix,
                publicBaseURL: publicBaseURL,
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey
            ))
            secretAccessKey = ""
            statusIsError = false
            statusMessage = L10n.r2SettingsSaved
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
