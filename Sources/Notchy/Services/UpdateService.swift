import AppKit
import CryptoKit
import NotchyCore
import Observation
import Security

/// Keeps Notchy up to date from its GitHub releases.
///
/// Checks the latest release a little after launch and every 6 hours (unless turned off), and on
/// request. Installing downloads Notchy.zip over HTTPS from GitHub, checks it against the
/// release's SHA-256, unpacks it and checks that it is a validly signed Notchy of the announced
/// version (and, when this copy is signed with a real identity, signed by the same one). Only
/// then is the app swapped in place, atomically, and relaunched. Any failure leaves the installed
/// app untouched.
@MainActor @Observable
final class UpdateService {
    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case installing(String)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var lastChecked: Date?
    let current = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!

    var available: ReleaseInfo? {
        if case .available(let r) = phase { return r }
        return nil
    }

    @ObservationIgnored private let feed: URL
    @ObservationIgnored private let localFeed: Bool
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var timer: Timer?

    init() {
        // Test builds can point at a local feed through Info.plist (covered by the signature, so
        // it can't be changed without replacing the app). Shipped builds use GitHub.
        var url = UpdateFeed.defaultURL, local = false
        if let s = Bundle.main.object(forInfoDictionaryKey: "NotchyUpdateFeed") as? String,
           let u = URL(string: s), UpdateFeed.isLocal(u) {
            url = u
            local = true
        }
        feed = url
        localFeed = local
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 300
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        c.httpAdditionalHeaders = ["User-Agent": "Notchy/\(version)", "Accept": "application/vnd.github+json"]
        session = URLSession(configuration: c, delegate: RedirectGuard(localFeed: local), delegateQueue: nil)
    }

    /// Automatic checks: shortly after launch, then every 6 hours.
    func setAutomatic(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.check(userInitiated: false)
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.check(userInitiated: false) } }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// QA builds only (local feed in Info.plist): check and install without a click.
    func runQAInstallIfAsked() {
        guard localFeed, ProcessInfo.processInfo.environment["NOTCHY_QA_UPDATE"] == "install" else { return }
        Task {
            await check(userInitiated: true)
            if available != nil { await install() }
        }
    }

    func check(userInitiated: Bool) async {
        switch phase {
        case .checking, .installing: return
        default: break
        }
        phase = .checking
        QALog.log("UPDATE checking \(feed.absoluteString) current=\(current)")
        do {
            let (data, response) = try await session.data(from: feed)
            lastChecked = Date()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                // No release published yet.
                phase = .upToDate
                QALog.log("UPDATE none published")
                return
            }
            guard status == 200, let release = UpdateFeed.parse(data, localFeed: localFeed) else {
                throw UpdateError("GitHub's answer could not be read (HTTP \(status)).")
            }
            if release.version > current {
                phase = .available(release)
                QALog.log("UPDATE available \(release.version)")
            } else {
                phase = .upToDate
                QALog.log("UPDATE up to date (latest \(release.version))")
            }
        } catch {
            // Quiet when automatic: being offline is not worth a message.
            phase = userInitiated ? .failed(Self.describe(error)) : .idle
            QALog.log("UPDATE check failed: \(Self.describe(error))")
        }
    }

    func install() async {
        guard let release = available else { return }
        let target = Bundle.main.bundleURL
        do {
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError("Notchy can't replace itself in \(target.deletingLastPathComponent().path). Download the update from GitHub instead.")
            }
            phase = .installing("Downloading \(release.version)…")
            guard let sumURL = release.checksumURL else { throw UpdateError("This release has no checksum, so it can't be verified.") }
            let (sumData, _) = try await session.data(from: sumURL)
            guard let expected = UpdateFeed.checksum(in: String(decoding: sumData, as: UTF8.self)) else {
                throw UpdateError("The release's checksum could not be read.")
            }
            // Staging sits on the same volume as the app, so the final swap is atomic.
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: target, create: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let (download, _) = try await session.download(from: release.zipURL)
            let zip = staging.appendingPathComponent(UpdateFeed.zipName)
            try FileManager.default.moveItem(at: download, to: zip)

            phase = .installing("Checking \(release.version)…")
            let newApp = try await Task.detached(priority: .userInitiated) {
                try Self.verify(zip: zip, expectedSHA256: expected, release: release, into: staging)
            }.value

            phase = .installing("Installing \(release.version)…")
            _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp)
            QALog.log("UPDATE installed \(release.version) at \(target.path)")
            relaunch(target)
        } catch {
            phase = .failed(Self.describe(error))
            QALog.log("UPDATE failed: \(Self.describe(error))")
        }
    }

    // MARK: Verification (off the main thread)

    /// Checks the download and unpacks it; returns the verified Notchy.app inside `dir`.
    nonisolated static func verify(zip: URL, expectedSHA256: String, release: ReleaseInfo, into dir: URL) throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        guard size > 0, size <= UpdateFeed.maxDownloadSize else { throw UpdateError("The download has an unexpected size.") }
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else { throw UpdateError("The download doesn't match the release's checksum.") }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        let unpacked = dir.appendingPathComponent("unpacked")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = unpacked.appendingPathComponent("Notchy.app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("The download could not be unpacked.")
        }

        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), v == release.version else {
            throw UpdateError("The download is not Notchy \(release.version).")
        }
        try checkSignature(of: app)
        // Downloaded by Notchy itself, so not quarantined; make sure nothing was carried over.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", app.path]
        try? xattr.run()
        xattr.waitUntilExit()
        return app
    }

    /// The new app must be validly signed. When this copy is signed with a real identity, the
    /// new one must also meet this copy's designated requirement: only the holder of the same
    /// signing key can produce an update. (Ad-hoc copies have no identity to compare.)
    nonisolated static func checkSignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The download is not signed.")
        }
        var requirement: SecRequirement?
        var me: SecCode?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me {
            var staticMe: SecStaticCode?
            var info: CFDictionary?
            if SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
               SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32,
               flags & 0x2 == 0 {   // not kSecCodeSignatureAdhoc
                SecCodeCopyDesignatedRequirement(staticMe, [], &requirement)
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError(requirement == nil ? "The download's signature is not valid." : "The download is not signed by the same developer.")
        }
    }

    // MARK: Relaunch

    /// Starts the new copy once this one has quit.
    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "relaunch", String(getpid()), app.path]
        do {
            try p.run()
        } catch {
            phase = .failed("Installed. Open Notchy again to finish.")
            return
        }
        NSApp.terminate(nil)
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }
}

struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Follows redirects only to trusted places (GitHub's download hosts, or the local test feed).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let localFeed: Bool
    init(localFeed: Bool) { self.localFeed = localFeed }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, UpdateFeed.isTrustedSource(url, localFeed: localFeed) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
