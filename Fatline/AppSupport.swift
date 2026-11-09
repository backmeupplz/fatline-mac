import SwiftUI

/// The few things the app asks of the system from more than one place.
enum AppSupport {
    /// Where this app keeps its drafts and feed. With no sandbox, Application Support is shared with
    /// every other build, so Fatline and Fatline Dev each need their own folder there.
    static var appFolder: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Fatline")
    }

    @MainActor
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor
    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
