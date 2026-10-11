import Foundation

/// Gets local edits uploaded to iCloud. Edits made through NotesShared are saved locally but
/// Notes does not upload them by itself; asking Notes to move the note into its own folder
/// makes Notes save and upload it, silently and without changing folder or id.
/// 当 Apple 开放官方 Notes API（写入会自动同步）时，删除这里的 AppleScript 带动与轮询。
@MainActor
public final class SyncCoordinator {
    let repository: NotesRepository

    public init(repository: NotesRepository) {
        self.repository = repository
    }

    /// Nudges the upload, then polls the note's cloud state until it reports synced.
    public func settle(id: String, timeout: Duration = .seconds(20)) async throws(NotesError) -> SyncReport {
        let clock = ContinuousClock()
        let start = clock.now
        let target = try repository.syncTarget(id: id)
        // Address the folder by id: after a move, `container of note` can come back as missing value.
        try AppleScript.run(
            "tell application \"Notes\" to move note id \"\(target.noteURI)\" to folder id \"\(target.folderURI)\"")
        let nudged = clock.now - start
        while true {
            let state = try repository.cloudState(id: id)
            if state.isSynced {
                return SyncReport(synced: true, nudge: nudged, total: clock.now - start, state: state)
            }
            if clock.now - start >= timeout {
                return SyncReport(synced: false, nudge: nudged, total: clock.now - start, state: state)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

public struct SyncReport: Sendable {
    public var synced: Bool
    public var nudge: Duration
    public var total: Duration
    public var state: CloudState
}
