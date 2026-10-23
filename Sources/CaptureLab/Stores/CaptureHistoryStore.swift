import AppKit
import Darwin
import Foundation
import ImageIO

enum CaptureHistoryError: LocalizedError {
    case busy
    case imageDataUnavailable
    case imageNotFound
    case metadataLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return L10n.historyBusy
        case .imageDataUnavailable:
            return L10n.historyImageDataUnavailable
        case .imageNotFound:
            return L10n.historyImageNotFound
        case .metadataLoadFailed(let message):
            return L10n.historyMetadataLoadFailed(message)
        }
    }
}

@MainActor
final class CaptureHistoryStore: ObservableObject {
    typealias ImageWriter = (Data, URL) throws -> Void
    typealias MetadataWriter = (Data, URL) throws -> Void

    struct ImageSnapshot {
        let item: CaptureHistoryItem
        let data: Data
    }

    @Published private(set) var items: [CaptureHistoryItem]
    @Published private(set) var loadError: CaptureHistoryError?
    @Published private(set) var isBusy = false
    @Published private(set) var permissionMigrationFailures = 0
    @Published private(set) var retention: CaptureHistoryRetention = .default
    @Published private(set) var recoveryProtectedIDs: Set<UUID> = []

    private struct MetadataDocument: Codable, Equatable {
        var schemaVersion: Int
        var items: [CaptureHistoryItem]
        var retention: CaptureHistoryRetention? = nil
        var recoveryProtectedIDs: Set<UUID>? = nil
    }

    // A damaged item must not prevent recovering an intact retention policy.
    private struct RetentionMetadata: Decodable {
        var retention: CaptureHistoryRetention?
        var recoveryProtectedIDs: Set<UUID>?
    }

    private let supportDirectory: URL
    let historyDirectory: URL
    var metadataURL: URL { historyDirectory.appendingPathComponent("history.json") }
    private let fileManager: FileManager
    private let imageWriter: ImageWriter
    private let metadataWriter: MetadataWriter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date
    // Reject reentrant access before opening another fd. POSIX record locks
    // are per process; closing that fd would release the outer operation's lock.
    private static var activeDirectories: Set<String> = []
    private var hasExclusiveLock = false
    private var didMigratePermissions = false
    #if DEBUG
    private(set) var lastLockDuration: TimeInterval = 0
    #endif

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        imageWriter: @escaping ImageWriter = { data, url in
            try CapturePrivateFile.writeAtomically(data, to: url)
        },
        metadataWriter: @escaping MetadataWriter = { data, url in
            try CapturePrivateFile.writeAtomically(data, to: url)
        },
        now: @escaping () -> Date = Date.init
    ) {
        // Freeze the resolved directories for the lifetime of this store, so
        // the lock, metadata and resources cannot diverge through an alias.
        let support = CaptureLabDataRoot.supportDirectory(environment: environment).resolvingSymlinksInPath()
        self.supportDirectory = support
        self.historyDirectory = support.appendingPathComponent("History", isDirectory: true).resolvingSymlinksInPath()
        self.fileManager = fileManager
        self.imageWriter = imageWriter
        self.metadataWriter = metadataWriter
        self.now = now
        self.items = []
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try withExclusiveHistoryLock {
                let exists = fileManager.fileExists(atPath: metadataURL.path)
                let loaded: [CaptureHistoryItem]
                if exists {
                    do {
                        retention = try readRetention()
                        loaded = try Self.loadItems(metadataURL: metadataURL, fileManager: fileManager, decoder: decoder)
                    } catch {
                        loadError = .metadataLoadFailed(error.localizedDescription)
                        _ = try? recoverAndPersistItems()
                        return
                    }
                } else {
                    loaded = try recoverAndPersistItems()
                }
                items = loaded
                let retained = retainingAutomatically(loaded)
                if retained != loaded {
                    do { try persist(retained) }
                    catch {
                        synchronizeAfterMetadataFailure(fallback: loaded)
                        throw error
                    }
                }
                items = retained
                Self.removeUnreferencedResources(retaining: retained, historyDirectory: historyDirectory, fileManager: fileManager)
            }
        } catch CaptureHistoryError.busy {
            // A live writer is not a damaged index. Opening history or refreshing
            // can retry later without an erroneous startup modal or cleanup.
        } catch {
            loadError = .metadataLoadFailed(error.localizedDescription)
        }
    }

    func record(data: Data, pixelSize: CGSize, createdAt: Date = Date()) throws -> CaptureHistoryItem {
        guard !data.isEmpty else {
            throw CaptureHistoryError.imageDataUnavailable
        }

        return try withExclusiveHistoryLock {
            // Another CaptureLab process may have committed history after this
            // store was initialized. Always merge against the current on-disk
            // snapshot while holding the cross-process lock instead of letting
            // stale in-memory state overwrite it.
            let currentItems = try latestItemsFromDisk()
            retention = try readRetention()
            let id = UUID()
            let fileName = "capture-\(Self.fileTimestampFormatter.string(from: createdAt))-\(id.uuidString).png"
            let fileURL = historyDirectory.appendingPathComponent(fileName)
            try imageWriter(data, fileURL)

            let item = CaptureHistoryItem(
                id: id,
                createdAt: createdAt,
                fileName: fileName,
                pixelWidth: Int(pixelSize.width),
                pixelHeight: Int(pixelSize.height)
            )
            let allItems = [item] + currentItems.filter { $0.id != item.id }
            let retainedItems = retainingAutomatically(allItems)
            do {
                try persist(retainedItems)
            } catch {
                // A custom or failing writer can theoretically replace the
                // metadata file and then report an error. Never remove the new
                // PNG when the on-disk metadata already references it, or the
                // rollback itself would create a dangling history entry.
                if let committedItems = try? Self.loadItems(
                    metadataURL: metadataURL,
                    fileManager: fileManager,
                    decoder: decoder
                ), committedItems.contains(where: { $0.id == item.id }) {
                    items = committedItems
                } else {
                    try? fileManager.removeItem(at: fileURL)
                }
                throw error
            }

            items = retainedItems
            Self.removeUnreferencedResources(
                retaining: retainedItems,
                historyDirectory: historyDirectory,
                fileManager: fileManager
            )
            return item
        }
    }

    /// Both resources are immutable revisions; one metadata replacement commits
    /// them together. A stale editor creates a separate entry instead of replacing
    /// a concurrent edit. All reads and retention share the cross-process lock.
    func saveEditable(preview: Data, project: Data, for previous: CaptureHistoryItem?,
                      pixelSize: CGSize, createdAt: Date) throws -> CaptureHistoryItem {
        guard !preview.isEmpty, !project.isEmpty, CaptureDocumentGeometry.validSize(pixelSize) else {
            throw CaptureHistoryError.imageDataUnavailable
        }
        return try withExclusiveHistoryLock {
            let current = try readableItems()
            retention = try readRetention()
            let existing = previous.flatMap { old in current.first { $0.id == old.id && $0.fileName == old.fileName } }
            let id = existing?.id ?? UUID()
            let stamp = existing?.createdAt ?? createdAt
            let stem = "capture-\(Self.fileTimestampFormatter.string(from: stamp))-\(UUID().uuidString)-\(id.uuidString)"
            let imageURL = historyDirectory.appendingPathComponent(stem + ".png")
            let projectURL = historyDirectory.appendingPathComponent(stem + ".capturelab")
            do {
                try imageWriter(preview, imageURL)
                try CaptureProjectStore.write(project, to: projectURL)
            } catch {
                try? fileManager.removeItem(at: imageURL)
                try? fileManager.removeItem(at: projectURL)
                throw error
            }
            let item = CaptureHistoryItem(id: id, createdAt: stamp, fileName: imageURL.lastPathComponent,
                                          pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height),
                                          projectFileName: projectURL.lastPathComponent, modifiedAt: now())
            let updated = retainingAutomatically([item] + current.filter { $0.id != id })
            do { try persist(updated) }
            catch {
                synchronizeAfterMetadataFailure(fallback: current)
                throw error
            }
            items = updated
            loadError = nil
            Self.removeUnreferencedResources(retaining: updated, historyDirectory: historyDirectory, fileManager: fileManager)
            return item
        }
    }

    struct EditableSnapshot {
        var item: CaptureHistoryItem
        var preview: Data
        var project: Data?
    }

    func editableSnapshot(for item: CaptureHistoryItem) throws -> EditableSnapshot {
        try withExclusiveHistoryLock(reclaimsAbandonedUpdates: false) {
            let current = try readableItems()
            items = current
            guard let entry = current.first(where: { $0.id == item.id }),
                  let imageURL = Self.historyFileURL(fileName: entry.fileName, historyDirectory: historyDirectory),
                  Self.isRegularFile(imageURL) else { throw CaptureHistoryError.imageNotFound }
            var project: Data?
            if let name = entry.projectFileName {
                guard let url = Self.projectFileURL(fileName: name, historyDirectory: historyDirectory),
                      Self.isRegularFile(url),
                      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= CaptureProjectStore.maximumBytes else { throw CaptureProjectError.invalid }
                project = try Data(contentsOf: url)
            }
            return EditableSnapshot(item: entry, preview: try Data(contentsOf: imageURL), project: project)
        }
    }

    /// Reload the durable snapshot under the same lock used by mutations.
    /// Invalid metadata leaves the previous snapshot and every image intact.
    func refresh() throws {
        do {
            try withExclusiveHistoryLock {
                if permissionMigrationFailures > 0 {
                    didMigratePermissions = false
                    migratePermissionsIfNeeded()
                }
                let refreshedItems: [CaptureHistoryItem]
                if fileManager.fileExists(atPath: metadataURL.path) {
                    refreshedItems = try Self.loadItems(
                        metadataURL: metadataURL,
                        fileManager: fileManager,
                        decoder: decoder
                    )
                } else {
                    refreshedItems = try recoverAndPersistItems()
                }
                retention = try readRetention()
                let retained = retainingAutomatically(refreshedItems)
                if retained != refreshedItems {
                    do { try persist(retained) }
                    catch {
                        synchronizeAfterMetadataFailure(fallback: refreshedItems)
                        throw error
                    }
                }
                items = retained
                loadError = nil
                Self.removeUnreferencedResources(
                    retaining: retained,
                    historyDirectory: historyDirectory,
                    fileManager: fileManager
                )
            }
        } catch CaptureHistoryError.busy {
            throw CaptureHistoryError.busy
        } catch {
            let historyError = CaptureHistoryError.metadataLoadFailed(error.localizedDescription)
            loadError = historyError
            throw historyError
        }
    }

    /// Commit the removal before reclaiming the image. An unsuccessful metadata
    /// write cannot delete an image that is still part of the durable snapshot.
    func remove(_ item: CaptureHistoryItem) throws {
        try withExclusiveHistoryLock {
            let currentItems = try latestItemsFromDisk()
            let retainedItems = currentItems.filter { $0.id != item.id }
            guard retainedItems.count != currentItems.count else {
                items = currentItems
                return
            }

            do {
                try persist(retainedItems)
            } catch {
                synchronizeAfterMetadataFailure(fallback: currentItems)
                throw error
            }
            items = retainedItems
            // Report a cleanup failure even though the metadata removal has
            // already committed. The caller can synchronize the visible list
            // while telling the user that the local PNG could not be removed.
            let retainedFileNames = Set(retainedItems.map(\.fileName))
            for removedItem in currentItems where removedItem.id == item.id {
                guard !retainedFileNames.contains(removedItem.fileName),
                      let fileURL = Self.historyFileURL(
                        fileName: removedItem.fileName,
                        historyDirectory: historyDirectory
                      ), Self.isRegularFile(fileURL) else { continue }
                try fileManager.removeItem(at: fileURL)
                if let name = removedItem.projectFileName,
                   let projectURL = Self.projectFileURL(fileName: name, historyDirectory: historyDirectory),
                   Self.isRegularFile(projectURL), !retainedItems.contains(where: { $0.projectFileName == name }) {
                    try fileManager.removeItem(at: projectURL)
                }
            }
        }
    }

    func url(for item: CaptureHistoryItem) -> URL {
        Self.historyFileURL(fileName: item.fileName, historyDirectory: historyDirectory)
            ?? historyDirectory.appendingPathComponent(".invalid-history-item")
    }

    func data(for item: CaptureHistoryItem) throws -> Data {
        try imageSnapshot(for: item).data
    }

    /// Resolve a potentially stale item by ID and read its bytes under the
    /// writer's lock. Returning a URL alone would let another crop delete that
    /// revision before the caller opens it.
    func imageSnapshot(for item: CaptureHistoryItem) throws -> ImageSnapshot {
        try withExclusiveHistoryLock(reclaimsAbandonedUpdates: false) {
            // If metadata is unreadable, retain the last known snapshot. Do not
            // guess a newer revision from orphaned files left by a failed crop.
            let currentItems = (try? Self.loadItems(
                metadataURL: metadataURL,
                fileManager: fileManager,
                decoder: decoder
            )) ?? items
            items = currentItems
            guard let currentItem = currentItems.first(where: { $0.id == item.id }),
                  let fileURL = Self.historyFileURL(
                    fileName: currentItem.fileName,
                    historyDirectory: historyDirectory
                  ), Self.isRegularFile(fileURL) else {
                throw CaptureHistoryError.imageNotFound
            }
            return ImageSnapshot(item: currentItem, data: try Data(contentsOf: fileURL))
        }
    }

    private func readRetention() throws -> CaptureHistoryRetention {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return retention }
        let document = try decoder.decode(RetentionMetadata.self, from: Data(contentsOf: metadataURL))
        recoveryProtectedIDs = document.recoveryProtectedIDs ?? []
        return (document.retention ?? .default).validated
    }

    private func retainingAutomatically(_ items: [CaptureHistoryItem]) -> [CaptureHistoryItem] {
        let retainedIDs = Set(retention.retaining(items, now: now()).map(\.id)).union(recoveryProtectedIDs)
        return items.filter { retainedIDs.contains($0.id) }
    }

    /// A reconstructed index cannot authorize deletion. Persist protection with
    /// the recovered entries so refreshes, other writers and restarts keep them
    /// until an explicit retention application (or individual deletion).
    private func recoverAndPersistItems() throws -> [CaptureHistoryItem] {
        let recovered = Self.recoverItemsFromDirectory(historyDirectory: historyDirectory, fileManager: fileManager)
        items = recovered
        let policy = (try? readRetention()) ?? retention
        let protected = Set(recovered.map(\.id))
        guard !recovered.isEmpty || fileManager.fileExists(atPath: metadataURL.path) else { return recovered }
        do { try persist(recovered, policy: policy, protecting: protected) }
        catch {
            synchronizeAfterMetadataFailure(fallback: recovered)
            throw error
        }
        Self.removeUnreferencedResources(retaining: recovered, historyDirectory: historyDirectory, fileManager: fileManager)
        return recovered
    }

    private func persist(_ items: [CaptureHistoryItem], policy: CaptureHistoryRetention? = nil,
                         protecting protectedIDs: Set<UUID>? = nil) throws {
        assert(hasExclusiveLock)
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let effective = policy ?? ((try? readRetention()) ?? retention)
        let protected = (protectedIDs ?? recoveryProtectedIDs).intersection(items.map(\.id))
        let document = MetadataDocument(schemaVersion: 3, items: items, retention: effective,
                                        recoveryProtectedIDs: protected.isEmpty ? nil : protected)
        try metadataWriter(encoder.encode(document), metadataURL)
        retention = effective
        recoveryProtectedIDs = protected
    }

    struct RetentionPreview {
        let policy: CaptureHistoryRetention
        let removingIDs: Set<UUID>
    }

    func previewRetention(_ policy: CaptureHistoryRetention) throws -> RetentionPreview {
        try withExclusiveHistoryLock {
            let current = try readableItems()
            let retainedIDs = Set(policy.retaining(current, now: now()).map(\.id))
            return RetentionPreview(policy: policy.validated, removingIDs: Set(current.map(\.id)).subtracting(retainedIDs))
        }
    }

    /// A new concurrent capture can change the set being deleted while the
    /// confirmation is visible. Return a new preview instead of deleting it.
    func applyRetention(_ preview: RetentionPreview) throws -> RetentionPreview? {
        try withExclusiveHistoryLock {
            let current = try readableItems()
            let retained = preview.policy.retaining(current, now: now())
            let removing = Set(current.map(\.id)).subtracting(retained.map(\.id))
            guard removing.isSubset(of: preview.removingIDs) else {
                return RetentionPreview(policy: preview.policy, removingIDs: removing)
            }
            do { try persist(retained, policy: preview.policy, protecting: []) }
            catch {
                synchronizeAfterMetadataFailure(fallback: current)
                throw error
            }
            items = retained
            loadError = nil
            Self.removeUnreferencedResources(retaining: retained, historyDirectory: historyDirectory, fileManager: fileManager)
            return nil
        }
    }

    private func readableItems() throws -> [CaptureHistoryItem] {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return try latestItemsFromDisk() }
        return try Self.loadItems(metadataURL: metadataURL, fileManager: fileManager, decoder: decoder)
    }

    private func synchronizeAfterMetadataFailure(fallback: [CaptureHistoryItem]) {
        assert(hasExclusiveLock)
        // A writer may report failure after its atomic replacement committed.
        // Only a readable durable snapshot permits cleanup; otherwise preserve
        // all images for later recovery, including a possibly committed crop.
        guard let documentData = try? Data(contentsOf: metadataURL),
              let document = try? decoder.decode(MetadataDocument.self, from: documentData),
              let committedItems = try? Self.loadItems(
            metadataURL: metadataURL,
            fileManager: fileManager,
            decoder: decoder
        ) else {
            items = fallback
            return
        }
        items = committedItems
        retention = (document.retention ?? .default).validated
        recoveryProtectedIDs = document.recoveryProtectedIDs ?? []
        Self.removeUnreferencedResources(
            // Keep every raw metadata reference during error recovery, even
            // when loadItems filtered a missing file, duplicate, or overflow.
            // Filtering must not be mistaken for a successfully committed
            // deletion or permit removing another referenced PNG.
            retaining: document.items,
            historyDirectory: historyDirectory,
            fileManager: fileManager
        )
    }

    private func latestItemsFromDisk() throws -> [CaptureHistoryItem] {
        if fileManager.fileExists(atPath: metadataURL.path),
           let persisted = try? Self.loadItems(
               metadataURL: metadataURL,
               fileManager: fileManager,
               decoder: decoder
           ) {
            return persisted
        }
        return try recoverAndPersistItems()
    }

    private func withExclusiveHistoryLock<T>(
        reclaimsAbandonedUpdates: Bool = true,
        _ operation: () throws -> T
    ) throws -> T {
        let directory = historyDirectory
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.activeDirectories.insert(key).inserted else {
            throw CaptureHistoryError.busy
        }
        defer { Self.activeDirectories.remove(key) }
        try CapturePrivateFile.ensureDirectory(supportDirectory, fileManager: fileManager)
        try CapturePrivateFile.ensureDirectory(directory, fileManager: fileManager)
        let descriptor = directory.appendingPathComponent(".history.lock").path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw Self.posixError(code: errno, operation: "open history lock") }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno, operation: "inspect history lock") }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw Self.posixError(code: errno, operation: "secure history lock")
        }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, F_SETLK, &lock) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EACCES {
                isBusy = true
                throw CaptureHistoryError.busy
            }
            throw Self.posixError(code: code, operation: "lock history")
        }
        hasExclusiveLock = true
        isBusy = false
        #if DEBUG
        let acquiredAt = ProcessInfo.processInfo.systemUptime
        #endif
        defer {
            #if DEBUG
            lastLockDuration = ProcessInfo.processInfo.systemUptime - acquiredAt
            #endif
            hasExclusiveLock = false
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }
        migratePermissionsIfNeeded()
        // Never reclaim pending files until the cross-process lock is held.
        // Reads can still succeed when an abandoned file cannot yet be removed.
        if reclaimsAbandonedUpdates {
            do { try Self.removeAbandonedImageUpdates(historyDirectory: directory, fileManager: fileManager) }
            catch {
                if items.isEmpty {
                    // Preserve readable history on cleanup failure, but only
                    // while holding the lock, never after a directory/open error.
                    items = (try? Self.loadItems(metadataURL: metadataURL, fileManager: fileManager, decoder: decoder))
                        ?? Self.recoverItemsFromDirectory(historyDirectory: directory, fileManager: fileManager)
                }
                throw error
            }
        }
        return try operation()
    }

    private func migratePermissionsIfNeeded() {
        assert(hasExclusiveLock)
        guard !didMigratePermissions else { return }
        didMigratePermissions = true
        guard let urls = try? fileManager.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: nil) else {
            permissionMigrationFailures = 1
            return
        }
        var failures = 0
        for url in urls where url.lastPathComponent == "history.json" || ["png", "capturelab", "pending"].contains(url.pathExtension.lowercased()) {
            // In particular, do not open/close .history.lock here: doing so would
            // release this process's record lock. Never recurse into Release/.
            var status = stat()
            guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
                  status.st_mode & S_IFMT == S_IFREG else { continue }
            guard status.st_nlink == 1 else { failures += 1; continue }
            do { try CapturePrivateFile.secureExistingFile(url) }
            catch { failures += 1 }
        }
        permissionMigrationFailures = failures
    }

    private static func posixError(code: Int32, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation): \(String(cString: strerror(code)))"]
        )
    }

    private static func loadItems(
        metadataURL: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) throws -> [CaptureHistoryItem] {
        let document = try decoder.decode(MetadataDocument.self, from: Data(contentsOf: metadataURL))
        let historyDirectory = metadataURL.deletingLastPathComponent()
        var seenIDs = Set<UUID>()
        var seenFileNames = Set<String>()
        return document.items.compactMap { item in
            guard let fileURL = historyFileURL(
                      fileName: item.fileName,
                      historyDirectory: historyDirectory
                  ), isRegularFile(fileURL),
                  item.projectFileName.map({ projectFileURL(fileName: $0, historyDirectory: historyDirectory) != nil }) ?? true,
                  seenIDs.insert(item.id).inserted,
                  seenFileNames.insert(item.fileName).inserted else {
                return nil
            }
            return item
        }
    }

    private static func recoverItemsFromDirectory(
        historyDirectory: URL,
        fileManager: FileManager
    ) -> [CaptureHistoryItem] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var recoveredIDs = Set<UUID>()

        return urls
            .filter {
                $0.pathExtension.lowercased() == "png"
                    && Self.isRegularFile($0)
            }
            .compactMap { url -> (item: CaptureHistoryItem, modifiedAt: Date)? in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                // Read dimensions without allocating a full-resolution bitmap.
                let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                return (
                    item: CaptureHistoryItem(
                        id: Self.recoveredID(from: url.lastPathComponent) ?? UUID(),
                        createdAt: createdAt,
                        fileName: url.lastPathComponent,
                        pixelWidth: max(0, width),
                        pixelHeight: max(0, height),
                        projectFileName: Self.isRegularFile(url.deletingPathExtension().appendingPathExtension("capturelab"))
                            ? url.deletingPathExtension().lastPathComponent + ".capturelab" : nil,
                        modifiedAt: values?.contentModificationDate ?? createdAt
                    ),
                    modifiedAt: values?.contentModificationDate ?? createdAt
                )
            }
            // A crop can leave both revisions after a crash or unreadable
            // metadata write. Their filenames retain the same capture ID;
            // choose the most recently written revision before sorting captures
            // by their recovered creation dates and enforcing retention.
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.item.fileName > $1.item.fileName
            }
            .filter { recoveredIDs.insert($0.item.id).inserted }
            .map(\.item)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func removeUnreferencedResources(
        retaining items: [CaptureHistoryItem],
        historyDirectory: URL,
        fileManager: FileManager
    ) {
        let retainedFileNames = Set(items.map(\.fileName) + items.compactMap(\.projectFileName))
        guard let urls = try? fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in urls where ["png", "capturelab"].contains(url.pathExtension.lowercased()) {
            guard !retainedFileNames.contains(url.lastPathComponent),
                  isRegularFile(url) else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func removeAbandonedImageUpdates(
        historyDirectory: URL,
        fileManager: FileManager
    ) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil
        )
        for url in urls {
            let fileName = url.lastPathComponent
            let prefix = fileName.hasPrefix(".capturelab-") ? ".capturelab-" : ".image-update-"
            let suffix = ".pending"
            guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { continue }
            let uuidText = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
            // UUID parsing alone accepts more spellings than the writer emits.
            // Require its exact canonical format to avoid claiming unknown files.
            guard let id = UUID(uuidString: uuidText), id.uuidString == uuidText,
                  isRegularFile(url) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private static func historyFileURL(fileName: String, historyDirectory: URL) -> URL? {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\0"),
              URL(fileURLWithPath: fileName).pathExtension.lowercased() == "png" else {
            return nil
        }

        let standardizedDirectory = historyDirectory.standardizedFileURL
        let candidate = standardizedDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedDirectory else {
            return nil
        }
        return candidate
    }

    private static func projectFileURL(fileName: String, historyDirectory: URL) -> URL? {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("\0"),
              URL(fileURLWithPath: fileName).pathExtension == "capturelab" else { return nil }
        return historyDirectory.appendingPathComponent(fileName)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var fileStatus = stat()
        guard url.path.withCString({ Darwin.lstat($0, &fileStatus) }) == 0 else {
            return false
        }
        return (fileStatus.st_mode & S_IFMT) == S_IFREG
    }

    private static func recoveredID(from fileName: String) -> UUID? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else {
            return nil
        }
        return UUID(uuidString: String(stem.suffix(36)))
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
