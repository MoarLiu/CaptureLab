import Foundation

/// A narrow synchronous bridge from export commands to AppKit's field editor.
///
/// `NSTextField` does not necessarily publish its field-editor value before a
/// toolbar action runs. Canvases register a weakly captured commit callback so
/// callers can flush pending text without changing focus or waiting for a
/// SwiftUI update pass.
@MainActor
final class CaptureEditingSession {
    static let shared = CaptureEditingSession()

    static func commitPendingTextEdits() {
        shared.commitPendingTextEdits()
    }

    private final class PendingTextCommitter {
        weak var owner: AnyObject?
        let commit: () -> Void

        init(owner: AnyObject, commit: @escaping () -> Void) {
            self.owner = owner
            self.commit = commit
        }
    }

    private var pendingTextCommitters: [ObjectIdentifier: PendingTextCommitter] = [:]

    func registerPendingTextCommitter(owner: AnyObject, commit: @escaping () -> Void) {
        pruneReleasedCommitters()
        pendingTextCommitters[ObjectIdentifier(owner)] = PendingTextCommitter(
            owner: owner,
            commit: commit
        )
    }

    func unregisterPendingTextCommitter(owner: AnyObject) {
        pendingTextCommitters.removeValue(forKey: ObjectIdentifier(owner))
    }

    func commitPendingTextEdits() {
        // Snapshot first so a callback can safely update registration state.
        pruneReleasedCommitters()
        let committers = Array(pendingTextCommitters.values)
        for committer in committers {
            committer.commit()
        }
    }

    private func pruneReleasedCommitters() {
        pendingTextCommitters = pendingTextCommitters.filter { $0.value.owner != nil }
    }
}
