import AppKit
import ImageIO
import NotchyCore
import SwiftUI

enum MediaCommand: Sendable {
    case togglePlayPause, next, previous
}

/// Decoded artwork plus its accent colour. CGImage is immutable, so sharing it is safe.
struct DecodedArtwork: @unchecked Sendable {
    let image: CGImage
    let tint: (r: Double, g: Double, b: Double)
}

enum ArtworkUpdate: Sendable {
    case unchanged, cleared, image(DecodedArtwork)
}

enum ArtworkDecoder {
    /// Decode off the main thread: thumbnail to 300 px and sample a 16x16 copy for the tint.
    static func decode(_ data: Data) -> DecodedArtwork? {
        // Artwork can come from any app or web page that reports Now Playing; skip oversized data.
        guard data.count <= 16 << 20 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 300,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return DecodedArtwork(image: img, tint: tint(of: img))
    }

    static func tint(of img: CGImage) -> (r: Double, g: Double, b: Double) {
        let side = 16
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? ArtworkTint.dominant(rgba: px) : ArtworkTint.neutral
    }
}

@MainActor protocol NowPlayingBackend: AnyObject {
    func start()
    func stop()
    func send(_ command: MediaCommand)
    func seek(to seconds: TimeInterval)
}

// MARK: - Model

@MainActor @Observable
final class NowPlayingModel {
    enum Source: String { case none, adapter, appleScript, demo }

    private(set) var info: NowPlayingInfo?
    private(set) var artwork: NSImage?
    private(set) var tint = Color(white: 0.86)
    private(set) var appIcon: NSImage?
    private(set) var appName = ""
    private(set) var source = Source.none
    /// In the compact wings: playing, or paused only briefly (skipping tracks must not flicker).
    private(set) var isLive = false
    private(set) var liveSince = Date()

    @ObservationIgnored var onTrackChange: ((NowPlayingInfo) -> Void)?
    @ObservationIgnored private var backend: (any NowPlayingBackend)?
    @ObservationIgnored private var pauseGrace: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var artCache: [String: (NSImage, Color)] = [:]
    @ObservationIgnored private var artCacheOrder: [String] = []
    @ObservationIgnored private let createdAt = Date()

    func start() {
        guard backend == nil else { return }
        if let adapter = AdapterBackend.bundled(model: self) {
            backend = adapter
            source = .adapter
            QALog.log("SOURCE adapter")
        } else {
            useFallback()
            return
        }
        backend?.start()
    }

    func stop() {
        backend?.stop()
        backend = nil
        source = .none
        receive(nil, artwork: .cleared, immediately: true)
    }

    /// The adapter could not run (missing files, or MediaRemote refused it): Music and Spotify only.
    func useFallback() {
        backend?.stop()
        let legacy = LegacyBackend(model: self)
        backend = legacy
        source = .appleScript
        QALog.log("SOURCE appleScript")
        legacy.start()
    }

    /// A restarting stream, or a player switching tracks, can report "nothing playing" for an
    /// instant. Hold a nil for a moment so the island does not flash idle and then re-announce
    /// the same track.
    func receive(_ new: NowPlayingInfo?, artwork update: ArtworkUpdate, immediately: Bool = false) {
        clearTask?.cancel()
        if new == nil, info != nil, !immediately {
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.apply(nil, artwork: .cleared)
            }
            return
        }
        apply(new, artwork: update)
    }

    private func apply(_ new: NowPlayingInfo?, artwork update: ArtworkUpdate) {
        let old = info
        let trackChanged = new?.trackKey != old?.trackKey
        info = new
        if trackChanged || new?.isPlaying != old?.isPlaying {
            QALog.log("NOWPLAYING title=\(new?.title ?? "-") artist=\(new?.artist ?? "-") playing=\(new?.isPlaying ?? false) app=\(new?.sourceBundleID ?? "-")")
        }
        if case .image = update { QALog.log("ARTWORK received") }

        if new?.sourceBundleID != old?.sourceBundleID { updateApp(new?.sourceBundleID) }

        switch update {
        case .image(let d):
            let img = NSImage(cgImage: d.image, size: NSSize(width: d.image.width, height: d.image.height))
            let color = Color(red: d.tint.r, green: d.tint.g, blue: d.tint.b)
            artwork = img
            tint = color
            if let key = new?.trackKey { cache(key, img, color) }
        case .cleared:
            artwork = nil
            tint = Color(white: 0.86)
        case .unchanged:
            if trackChanged {
                if let key = new?.trackKey, let hit = artCache[key] {
                    artwork = hit.0
                    tint = hit.1
                } else {
                    artwork = nil
                    tint = Color(white: 0.86)
                }
            }
        }

        if let new, new.isPlaying {
            pauseGrace?.cancel()
            if !isLive { isLive = true; liveSince = Date() }
        } else if new == nil {
            pauseGrace?.cancel()
            isLive = false
        } else if isLive, pauseGrace == nil || pauseGrace!.isCancelled {
            pauseGrace = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled, self.info?.isPlaying != true else { return }
                self.isLive = false
                self.pauseGrace = nil
            }
        }

        // Peek on a new track, but not for whatever was already playing at launch.
        if trackChanged, let new, new.isPlaying, Date().timeIntervalSince(createdAt) > 2.5 {
            onTrackChange?(new)
        }
    }

    // MARK: Controls

    func send(_ command: MediaCommand) {
        if command == .togglePlayPause, var i = info {
            // Optimistic: flip immediately, the stream confirms shortly after.
            let now = Date()
            i.elapsed = i.position(at: now)
            i.timestamp = now
            i.isPlaying.toggle()
            receive(i, artwork: .unchanged)
        }
        backend?.send(command)
    }

    func seek(toFraction f: Double) {
        guard var i = info, let d = i.duration else { return }
        let t = max(0, min(1, f)) * d
        i.elapsed = t
        i.timestamp = Date()
        info = i
        backend?.seek(to: t)
    }

    // MARK: Demo

    func showDemo(_ info: NowPlayingInfo, artwork: NSImage?, tint: Color) {
        source = .demo
        self.info = info
        self.artwork = artwork
        self.tint = tint
        isLive = info.isPlaying
        updateApp(info.sourceBundleID)
    }

    // MARK: Private

    private func updateApp(_ bundleID: String?) {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            appIcon = nil
            appName = bundleID == "com.spotify.client" ? "Spotify" : ""
            return
        }
        appIcon = NSWorkspace.shared.icon(forFile: url.path)
        appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func cache(_ key: String, _ img: NSImage, _ color: Color) {
        if artCache[key] == nil { artCacheOrder.append(key) }
        artCache[key] = (img, color)
        while artCacheOrder.count > 24 { artCache.removeValue(forKey: artCacheOrder.removeFirst()) }
    }
}

// MARK: - mediaremote-adapter (all players, including browsers)

/// Runs `/usr/bin/perl mediaremote-adapter.pl <framework> stream` once and folds its JSON lines.
/// Perl is an Apple platform binary, so MediaRemote still answers it on macOS 15.4+.
@MainActor
final class AdapterBackend: NowPlayingBackend {
    private let stream: AdapterStream

    static func bundled(model: NowPlayingModel) -> AdapterBackend? {
        let res = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let script = res.appendingPathComponent("Resources/mediaremote-adapter.pl").path
        let framework = res.appendingPathComponent("Frameworks/MediaRemoteAdapter.framework").path
        guard FileManager.default.fileExists(atPath: script),
              FileManager.default.fileExists(atPath: framework + "/MediaRemoteAdapter") else { return nil }
        return AdapterBackend(script: script, framework: framework, model: model)
    }

    private init(script: String, framework: String, model: NowPlayingModel) {
        stream = AdapterStream(
            script: script, framework: framework,
            onUpdate: { [weak model] info, art in
                Task { @MainActor in model?.receive(info, artwork: art) }
            },
            onFatal: { [weak model] in
                Task { @MainActor in model?.useFallback() }
            })
    }

    func start() { stream.start() }
    func stop() { stream.stop() }

    func send(_ command: MediaCommand) {
        let id = switch command {
        case .togglePlayPause: "2"
        case .next: "4"
        case .previous: "5"
        }
        stream.run(["send", id])
    }

    func seek(to seconds: TimeInterval) {
        stream.run(["seek", String(Int64(seconds * 1_000_000))])
    }
}

/// Process and parsing state, confined to `queue`.
final class AdapterStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "notchy.nowplaying.adapter", qos: .utility)
    private let perl = URL(fileURLWithPath: "/usr/bin/perl")
    /// perl honours PERL5OPT, PERL5LIB and similar variables, and its child process acts with
    /// Notchy's permissions. Start it with a minimal environment, so nothing passed to Notchy
    /// at launch can make it load other code.
    private static let environment: [String: String] = {
        let keep: Set = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        var env = ProcessInfo.processInfo.environment.filter { keep.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }()
    private let script: String
    private let framework: String
    private let onUpdate: @Sendable (NowPlayingInfo?, ArtworkUpdate) -> Void
    private let onFatal: @Sendable () -> Void

    private var process: Process?
    private var parser = AdapterStreamState()
    private var buffer = LineBuffer()
    private var stopped = true
    private var failures = 0
    private var launchedAt = Date()
    private var sawData = false

    init(script: String, framework: String,
         onUpdate: @escaping @Sendable (NowPlayingInfo?, ArtworkUpdate) -> Void,
         onFatal: @escaping @Sendable () -> Void) {
        self.script = script
        self.framework = framework
        self.onUpdate = onUpdate
        self.onFatal = onFatal
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            killOrphans()
            launch()
        }
    }

    /// A stream left behind by a crashed or force-killed Notchy only exits on its next write
    /// (SIGPIPE). Reap any whose parent is gone before starting a new one.
    private func killOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, f[1] == "1", f[2].contains(script), let pid = Int32(f[0]) else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// Synchronous so the child is gone before the app exits.
    func stop() {
        queue.sync {
            stopped = true
            process?.terminate()
            process = nil
        }
    }

    /// One-shot commands (send, seek) in their own short-lived process.
    func run(_ args: [String]) {
        queue.async { [self] in
            let p = Process()
            p.executableURL = perl
            p.arguments = [script, framework] + args
            p.environment = Self.environment
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    private func launch() {
        parser = AdapterStreamState()
        buffer = LineBuffer()
        sawData = false
        let p = Process()
        p.executableURL = perl
        p.arguments = [script, framework, "stream", "--micros", "--debounce=40"]
        p.environment = Self.environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.queue.async { self.feed(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            guard let self else { return }
            self.queue.async { self.exited(status: status, reason: reason) }
        }
        do {
            try p.run()
            process = p
            launchedAt = Date()
        } catch {
            onFatal()
        }
    }

    private func feed(_ data: Data) {
        for line in buffer.append(data) {
            guard let u = parser.apply(line: line) else { continue }
            sawData = true
            var art = ArtworkUpdate.unchanged
            if u.artworkChanged {
                if let b64 = u.artwork, let bytes = Data(base64Encoded: b64), let decoded = ArtworkDecoder.decode(bytes) {
                    art = .image(decoded)
                } else if u.artwork == nil {
                    art = .cleared
                }
            }
            onUpdate(u.info, art)
        }
    }

    private func exited(status: Int32, reason: Process.TerminationReason) {
        process = nil
        guard !stopped else { return }
        // Upstream asks not to re-invoke after a fatal error (non-zero exit): fall back instead.
        if reason == .exit, status != 0, !sawData {
            stopped = true
            onFatal()
            return
        }
        if Date().timeIntervalSince(launchedAt) > 120 { failures = 0 }
        failures += 1
        guard failures <= 5 else {
            stopped = true
            onFatal()
            return
        }
        let delay = min(30, pow(2, Double(failures - 1)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.launch()
        }
    }
}

// MARK: - Fallback: Music and Spotify

/// Event-driven via the players' own distributed notifications (no polling, no permission).
/// AppleScript (Automation permission) is used only for artwork, Music's playhead and controls.
@MainActor
final class LegacyBackend: NowPlayingBackend {
    private static let spotify = "com.spotify.client"
    private static let music = "com.apple.Music"

    private weak var model: NowPlayingModel?
    private var observers: [NSObjectProtocol] = []
    private var players: [String: NowPlayingInfo] = [:]
    private var lastArtKey: String?
    private let scripts = AppleScriptRunner()

    init(model: NowPlayingModel) { self.model = model }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        for (name, bundle) in [("com.spotify.client.PlaybackStateChanged", Self.spotify), ("com.apple.Music.playerInfo", Self.music)] {
            observers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] n in
                let parsed = Self.parse(n.userInfo ?? [:], bundle: bundle)
                MainActor.assumeIsolated { self?.update(bundle, parsed.info, stopped: parsed.stopped) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id { self?.update(id, nil, stopped: true) } }
        })
        // Pick up whatever is already playing (only asks apps that are running; never launches them).
        for bundle in [Self.spotify, Self.music] where isRunning(bundle) {
            scripts.probe(bundle) { [weak self] info in self?.update(bundle, info, stopped: info == nil) }
        }
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// The player to script: only Music or Spotify. The current track can still come from the
    /// adapter right after a fallback, and its bundle ID must never reach AppleScript source.
    private var target: String? {
        guard let bundle = model?.info?.bundleID, bundle == Self.music || bundle == Self.spotify else { return nil }
        return bundle
    }

    func send(_ command: MediaCommand) {
        guard let bundle = target else { return }
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        scripts.run("tell application id \"\(bundle)\" to \(verb)")
    }

    func seek(to seconds: TimeInterval) {
        guard let bundle = target, seconds.isFinite else { return }
        scripts.run("tell application id \"\(bundle)\" to set player position to \(seconds)")
    }

    private func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    private func update(_ bundle: String, _ info: NowPlayingInfo?, stopped: Bool) {
        if stopped || info == nil { players.removeValue(forKey: bundle) } else { players[bundle] = info }
        // Music does not include the playhead in its notification; ask once.
        if bundle == Self.music, let i = info, i.elapsed == nil {
            scripts.position(bundle) { [weak self] pos in
                guard let self, var cur = self.players[bundle], cur.trackKey == i.trackKey else { return }
                cur.elapsed = pos
                cur.timestamp = Date()
                self.players[bundle] = cur
                self.publish()
            }
        }
        publish()
    }

    private func publish() {
        let best = players.values.first(where: \.isPlaying) ?? players.values.first
        guard let model else { return }
        model.receive(best, artwork: .unchanged)
        guard let best, best.trackKey != lastArtKey else { return }
        lastArtKey = best.trackKey
        scripts.artwork(best.bundleID) { [weak model] art in
            guard let model, model.info?.trackKey == best.trackKey, let art else { return }
            model.receive(model.info, artwork: .image(art))
        }
    }

    nonisolated static func parse(_ u: [AnyHashable: Any], bundle: String) -> (info: NowPlayingInfo?, stopped: Bool) {
        let state = u["Player State"] as? String ?? ""
        guard state != "Stopped", let title = u["Name"] as? String, !title.isEmpty else { return (nil, true) }
        let durationMs = (u["Duration"] as? NSNumber ?? u["Total Time"] as? NSNumber)?.doubleValue
        let position = (u["Playback Position"] as? NSNumber)?.doubleValue
        return (NowPlayingInfo(
            bundleID: bundle, title: title,
            artist: u["Artist"] as? String ?? "", album: u["Album"] as? String ?? "",
            duration: durationMs.map { $0 / 1000 }, elapsed: position, timestamp: Date(),
            playbackRate: 1, isPlaying: state == "Playing"), false)
    }
}

/// NSAppleScript on one serial queue (it is not thread-safe). Results come back on the main actor.
final class AppleScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "notchy.applescript", qos: .utility)

    private func eval(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    func run(_ source: String) {
        queue.async { [self] in _ = eval(source) }
    }

    func position(_ bundle: String, _ done: @escaping @MainActor @Sendable (Double) -> Void) {
        queue.async { [self] in
            guard let s = eval("tell application id \"\(bundle)\" to return player position as text")?.stringValue,
                  let v = Double(s.replacingOccurrences(of: ",", with: ".")) else { return }
            Task { @MainActor in done(v) }
        }
    }

    func probe(_ bundle: String, _ done: @escaping @MainActor @Sendable (NowPlayingInfo?) -> Void) {
        let spotify = bundle == "com.spotify.client"
        let src = """
        tell application id "\(bundle)"
          if player state is stopped then return ""
          set t to current track
          set s to ASCII character 31
          return (player state as text) & s & (name of t) & s & (artist of t) & s & (album of t) & s & (player position as text) & s & (duration of t as text)
        end tell
        """
        queue.async { [self] in
            var info: NowPlayingInfo?
            if let r = eval(src)?.stringValue, !r.isEmpty {
                let p = r.components(separatedBy: "\u{1F}")
                if p.count == 6 {
                    let num = { (x: String) in Double(x.replacingOccurrences(of: ",", with: ".")) }
                    let dur = num(p[5]).map { spotify ? $0 / 1000 : $0 }
                    info = NowPlayingInfo(bundleID: bundle, title: p[1], artist: p[2], album: p[3],
                                          duration: dur, elapsed: num(p[4]), timestamp: Date(),
                                          playbackRate: 1, isPlaying: p[0] == "playing")
                }
            }
            let result = info
            Task { @MainActor in done(result) }
        }
    }

    func artwork(_ bundle: String, _ done: @escaping @MainActor @Sendable (DecodedArtwork?) -> Void) {
        queue.async { [self] in
            if bundle == "com.spotify.client" {
                // Spotify only gives a URL. Fetch it only over HTTPS from Spotify's image CDN, off
                // this queue and with a timeout, so a slow server never holds up the controls.
                guard let s = eval("tell application id \"\(bundle)\" to return artwork url of current track")?.stringValue,
                      let url = SpotifyArtwork.url(s) else {
                    Task { @MainActor in done(nil) }
                    return
                }
                Self.session.dataTask(with: url) { data, _, _ in
                    let art = data.flatMap(ArtworkDecoder.decode)
                    Task { @MainActor in done(art) }
                }.resume()
                return
            }
            let data = eval("tell application id \"\(bundle)\" to return data of artwork 1 of current track")?.data
            let art = data.flatMap(ArtworkDecoder.decode)
            Task { @MainActor in done(art) }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 10
        return URLSession(configuration: c)
    }()
}
