import AppKit
import ApplicationServices

/// Asking for Accessibility, including after an update.
///
/// Releases that aren't signed with a fixed identity look like a different app to macOS after
/// every update. The old entry stays in Privacy & Security → Accessibility, still switched on, but
/// it no longer applies, and asking again doesn't replace it. So when the permission is missing,
/// clear this app's entry first (`tccutil reset`, the fix macOS apps give their users for exactly
/// this), then ask: macOS lists the app afresh, and switching it on works.
@MainActor
enum AccessibilityAccess {
    static var granted: Bool { AXIsProcessTrusted() }

    static func request() {
        guard !granted else { return }
        if let id = Bundle.main.bundleIdentifier {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                QALog.log("ACCESS reset status=\(p.terminationStatus)")
            }
        }
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            openSettings()
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
