import AppKit
import Combine
import NotesKit
import SwiftUI

// SwiftUI here avoids macros (@State, @Observable): the Command Line Tools have no SwiftUI
// macro plugin. 当工具链带 SwiftUI 宏插件时，可改用 @Observable / @State。

/// Permission setup window. Shows the live state of both permissions and takes the user to
/// the right page in System Settings.
@MainActor
enum Onboarding {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Apple Notes MCP"
        let model = PermissionModel()
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, close: { app.terminate(nil) }))
        window.center()
        window.isReleasedWhenClosed = false
        let delegate = CloseDelegate()
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        app.activate()
        withExtendedLifetime((delegate, model)) { app.run() }
    }

    /// Opens the window through LaunchServices, so it runs as the app itself (with the app's
    /// own permissions) even when the server was started by another program.
    nonisolated static func openFromServer() {
        guard let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundle.path, "--args", "--onboarding"]
        try? process.run()
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
    }
}

/// Live permission state, refreshed every second.
@MainActor
final class PermissionModel: ObservableObject {
    @Published var disk = Permissions.fullDiskAccess()
    @Published var automation = Permissions.automation(ask: false)
    private var timer: AnyCancellable?

    init() {
        Permissions.launchNotesInBackground()
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        disk = Permissions.fullDiskAccess()
        automation = Permissions.automation(ask: false)
    }

    func askForAutomation() {
        Permissions.launchNotesInBackground()
        Task.detached {
            let status = Permissions.automation(ask: true)
            await MainActor.run { self.automation = status }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: PermissionModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let AI assistants use your Apple Notes").font(.title2).bold()
                Text("Apple Notes MCP needs two permissions. They belong to this app, so you only grant them once.")
                    .foregroundStyle(.secondary)
            }
            PermissionRow(
                title: "Full Disk Access", detail: "To read your notes. Turn on Apple Notes MCP in the list; if it is missing, click + and choose this app.",
                status: model.disk
            ) {
                Button("Open Settings") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettings) }
                Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
            PermissionRow(
                title: "Automation → Notes", detail: "To have Notes upload edits to iCloud and move deleted notes to Recently Deleted.",
                status: model.automation
            ) {
                if model.automation == .notDetermined || model.automation == .unknown {
                    Button("Allow") { model.askForAutomation() }
                }
                Button("Open Settings") { NSWorkspace.shared.open(Permissions.automationSettings) }
            }
            Text("If a switch is on but the status stays red, select Apple Notes MCP in the list, remove it with −, and add it again.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(model.disk == .granted && model.automation == .granted ? "Done" : "Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct PermissionRow<Buttons: View>: View {
    let title: String
    let detail: String
    let status: Permissions.Status
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status == .granted ? .green : .orange).font(.title2)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { buttons }
            }
        }
    }

    var label: String {
        switch status {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case .unknown: "Checking…"
        }
    }
}
