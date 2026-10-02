import AppKit
import NotchyCore
import ServiceManagement

/// The app was called Notchy up to 1.0.2. Those copies update by replacing their own Notchy.app,
/// so the first ponyhub they install still sits under the old name. On its first launch there,
/// it renames its bundle to ponyhub.app and starts again from the new place. Settings carry over
/// (same bundle identifier). Nothing happens when the rename isn't possible (a read-only folder,
/// or a ponyhub.app already there): it keeps running as it is.
@MainActor
enum LegacyRename {
    static let renamedFlag = "--renamed"
    static let loginFlag = "--restore-login-item"

    /// Returns only when no rename happened.
    static func runIfNeeded(_ args: [String]) {
        let old = Bundle.main.bundleURL
        guard old.lastPathComponent == "\(AppInfo.legacyName).app" else { return }
        let new = old.deletingLastPathComponent().appendingPathComponent("\(AppInfo.name).app")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.isWritableFile(atPath: old.deletingLastPathComponent().path) else { return }

        // Launch at login points at the old place; drop it here and add it back from the new one.
        let login = SMAppService.mainApp.status == .enabled
        if login { try? SMAppService.mainApp.unregister() }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            QALog.log("RENAME failed: \(error.localizedDescription)")
            if login { try? SMAppService.mainApp.register() }
            return
        }
        QALog.log("RENAME \(old.lastPathComponent) → \(new.lastPathComponent)")
        relaunch(new, args: [renamedFlag] + (login ? [loginFlag] : []))
        exit(0)
    }

    /// In the renamed copy: put launch at login back if it was on.
    static func finish(_ args: [String]) {
        guard args.contains(loginFlag) else { return }
        try? SMAppService.mainApp.register()
    }

    /// Opens the app once this process has gone (an app can't be opened again while it runs).
    private static func relaunch(_ app: URL, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "pid=$1; app=$2; shift 2; while /bin/kill -0 \"$pid\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$app\" --args \"$@\"",
                       "relaunch", String(getpid()), app.path] + args
        try? p.run()
    }
}
