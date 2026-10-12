import AppKit
import CoreServices
import Foundation

/// The two privacy permissions the app needs, checked live.
public enum Permissions {
    public enum Status: Sendable, Equatable {
        case granted, denied, notDetermined
        /// Notes is not running, so Automation cannot be checked yet.
        case unknown
    }

    public static let notesBundleID = "com.apple.Notes"

    /// Full Disk Access, tested by actually reading the Notes database file.
    public static func fullDiskAccess() -> Status {
        guard let handle = FileHandle(forReadingAtPath: ReadStore.storeURL.path) else { return .denied }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)).map { $0.isEmpty ? .denied : .granted } ?? .denied
    }

    /// Automation → Notes. With `ask`, macOS shows its consent prompt when not decided yet.
    public static func automation(ask: Bool) -> Status {
        var target = AEAddressDesc()
        let bundleID = Array(notesBundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bundleID, bundleID.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown
        }
    }

    /// Starts Notes in the background so its Automation permission can be checked.
    @MainActor public static func launchNotesInBackground() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesBundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    public static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    public static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
