// FakePlayer: a minimal "music app" for QA runs.
//  - Publishes a track to macOS Now Playing (MPNowPlayingInfoCenter) with artwork, so
//    Notchy's Now Playing path is exercised end to end through the real system.
//  - Logs every remote command it receives (play/pause/next/previous/seek) to stdout,
//    which proves the island's buttons reach the player.
//  - Covers the screen below the menu bar with a light backdrop window, so the black island
//    is measurable in screenshots, and logs clicks that land on it (click-through checks).
import AVFoundation
import AppKit
import MediaPlayer

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ s: String) { print("FP \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(s)") }

struct Track { let title: String; let artist: String; let album: String; let duration: Double; let color: NSColor }
let tracks = [
    Track(title: "QA Track One", artist: "The Testers", album: "Seamless", duration: 214, color: .systemPink),
    Track(title: "QA Track Two", artist: "The Testers", album: "Seamless", duration: 187, color: .systemTeal),
    Track(title: "QA Track Three", artist: "The Testers", album: "Seamless", duration: 251, color: .systemOrange),
]

/// One second of a barely audible tone as an in-memory WAV, looped while "playing".
func toneWAV() -> Data {
    let rate = 44100, n = rate
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
    for i in 0..<n { u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8))) }
    return d
}

final class Player: NSObject {
    var audio: AVAudioPlayer?
    var index = 0
    var playing = true
    var elapsed = 30.0
    var since = Date()

    func artwork(_ c: NSColor) -> MPMediaItemArtwork {
        let size = NSSize(width: 300, height: 300)
        let img = NSImage(size: size, flipped: false) { r in
            NSGradient(starting: c, ending: .black)?.draw(in: r, angle: -60)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 150, y: 150, width: 110, height: 110)).fill()
            return true
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in img }
    }

    func position() -> Double { playing ? elapsed + Date().timeIntervalSince(since) : elapsed }

    func publish() {
        let t = tracks[index]
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: t.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position(),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPMediaItemPropertyArtwork: artwork(t.color),
        ]
        center.playbackState = playing ? .playing : .paused
        log("PUBLISH title=\(t.title) playing=\(playing) position=\(Int(position()))")
    }

    func setPlaying(_ p: Bool) {
        elapsed = position()
        since = Date()
        playing = p
        if p { audio?.play() } else { audio?.pause() }
        publish()
    }

    func start() {
        do {
            audio = try AVAudioPlayer(data: toneWAV())
            audio?.numberOfLoops = -1
            audio?.volume = 0.05
            log("AUDIO \(audio?.play() == true ? "playing" : "not playing")")
        } catch {
            log("AUDIO unavailable: \(error.localizedDescription)")
        }
        let rc = MPRemoteCommandCenter.shared()
        rc.togglePlayPauseCommand.addTarget { [unowned self] _ in log("CMD toggle"); setPlaying(!playing); return .success }
        rc.playCommand.addTarget { [unowned self] _ in log("CMD play"); setPlaying(true); return .success }
        rc.pauseCommand.addTarget { [unowned self] _ in log("CMD pause"); setPlaying(false); return .success }
        rc.nextTrackCommand.addTarget { [unowned self] _ in
            log("CMD next"); index = (index + 1) % tracks.count; elapsed = 0; since = Date(); publish(); return .success
        }
        rc.previousTrackCommand.addTarget { [unowned self] _ in
            log("CMD previous"); index = (index + tracks.count - 1) % tracks.count; elapsed = 0; since = Date(); publish(); return .success
        }
        rc.changePlaybackPositionCommand.addTarget { [unowned self] e in
            let p = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? -1
            log("CMD seek position=\(Int(p))"); elapsed = p; since = Date(); publish(); return .success
        }
        publish()
    }
}

final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.84, alpha: 1).setFill()
        dirtyRect.fill()
    }
    override func mouseDown(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let top = NSScreen.screens[0].frame.maxY
        log("BACKDROP_CLICK x=\(Int(p.x)) y=\(Int(top - p.y))")
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let player = Player()
    var window: NSWindow!
    var nextSignal: DispatchSourceSignal?
    var toggleSignal: DispatchSourceSignal?
    var crowdSignal: DispatchSourceSignal?
    var crowd: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens[0]
        window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Backdrop()
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.orderFrontRegardless()
        player.start()
        // SIGUSR1: next track from the test script (simulates the user skipping in the player).
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { [unowned self] in
            log("SIGNAL next")
            player.index = (player.index + 1) % tracks.count
            player.elapsed = 0
            player.since = Date()
            player.publish()
        }
        s.resume()
        nextSignal = s
        // SIGUSR2: pause/resume from the test script (the user pressing pause in the player).
        signal(SIGUSR2, SIG_IGN)
        let p = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        p.setEventHandler { [unowned self] in
            log("SIGNAL toggle")
            player.setPlaying(!player.playing)
        }
        p.resume()
        toggleSignal = p
        // SIGHUP: add (or remove) a wide menu bar icon, crowding the menu bar next to the notch.
        signal(SIGHUP, SIG_IGN)
        let h = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        h.setEventHandler { [unowned self] in
            if let c = crowd {
                NSStatusBar.system.removeStatusItem(c)
                crowd = nil
                log("CROWD removed")
            } else {
                // The width comes from the file named by FP_CROWD_FILE (the test works it out).
                let text = ProcessInfo.processInfo.environment["FP_CROWD_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                let width = text.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 160
                let c = NSStatusBar.system.statusItem(withLength: width)
                c.button?.title = "QA crowding the menu bar"
                crowd = c
                log("CROWD added width=\(Int(width))")
            }
        }
        h.resume()
        crowdSignal = h
        log("READY")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
