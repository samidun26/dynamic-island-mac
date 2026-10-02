import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchyCore

final class ActivityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func entry(_ k: ActivityKind, _ p: Int, transient: Bool = false, compact: Bool = true, at dt: TimeInterval = 0) -> ActivityEntry {
        ActivityEntry(kind: k, priority: p, transient: transient, showsCompact: compact, hasPage: !transient, since: t0 + dt)
    }

    func testPriorityThenRecency() {
        let q = ActivityQueue(entries: [
            entry(.nowPlaying, ActivityPriority.nowPlaying),
            entry(.timer, ActivityPriority.timer, at: -60),
            entry(.calendar, ActivityPriority.eventSoon, at: 10),
        ])
        XCTAssertEqual(q.compactOrder, [.timer, .nowPlaying, .calendar])
        XCTAssertEqual(q.secondaries, [.nowPlaying, .calendar])
        XCTAssertEqual(q.pages, [.activity(.timer), .activity(.nowPlaying), .activity(.calendar), .home])
    }

    func testTransientAlwaysWinsAndIsNeverAPageOrSecondary() {
        var q = ActivityQueue(entries: [
            entry(.nowPlaying, ActivityPriority.nowPlaying),
            entry(.hud, 0, transient: true),
        ])
        q.preferred = .nowPlaying
        XCTAssertEqual(q.primary, .hud)
        XCTAssertEqual(q.secondaries, [], "a HUD takes the whole island")
        XCTAssertEqual(q.pages, [.activity(.nowPlaying), .home])
    }

    func testSwipePreferenceAndCycling() {
        var q = ActivityQueue(entries: [
            entry(.nowPlaying, ActivityPriority.nowPlaying),
            entry(.timer, ActivityPriority.timer),
            entry(.calendar, ActivityPriority.eventSoon, compact: false),
        ])
        XCTAssertEqual(q.primary, .timer)
        q.preferred = q.cycled(by: 1)
        XCTAssertEqual(q.primary, .nowPlaying)
        q.preferred = q.cycled(by: 1)
        XCTAssertEqual(q.primary, .timer, "wraps around, skipping activities without compact views")
        XCTAssertEqual(q.cycled(by: -1), .nowPlaying)
    }

    func testEmptyQueueHasOnlyHome() {
        let q = ActivityQueue(entries: [])
        XCTAssertNil(q.primary)
        XCTAssertNil(q.cycled(by: 1))
        XCTAssertEqual(q.pages, [.home])
    }
}

final class HoverIntentTests: XCTestCase {
    func testDwellOpensAfterDelay() {
        var h = HoverIntent(openDelay: 0.12, closeDelay: 0.25)
        h.track(CGPoint(x: 0, y: 0), at: 10.00, inside: true)
        XCTAssertFalse(h.shouldOpen(at: 10.05))
        h.track(CGPoint(x: 2, y: 0), at: 10.06, inside: true) // slow drift keeps the dwell
        XCTAssertTrue(h.shouldOpen(at: 10.12))
    }

    func testFastSweepAcrossTheNotchDoesNotOpen() {
        var h = HoverIntent(openDelay: 0.12, closeDelay: 0.25, passThroughSpeed: 900)
        var t = 10.0, x: CGFloat = 0
        for _ in 0..<10 { // 2000 pt/s
            h.track(CGPoint(x: x, y: 0), at: t, inside: true)
            t += 0.016; x += 32
            XCTAssertFalse(h.shouldOpen(at: t))
        }
        h.track(CGPoint(x: x, y: 0), at: t, inside: false)
        XCTAssertFalse(h.shouldOpen(at: t + 1))
    }

    func testCloseWaitsAndReentryCancels() {
        var h = HoverIntent(openDelay: 0.12, closeDelay: 0.25)
        h.track(.zero, at: 0, inside: true)
        h.track(CGPoint(x: 300, y: 0), at: 1, inside: false)
        XCTAssertFalse(h.shouldClose(at: 1.2))
        XCTAssertTrue(h.shouldClose(at: 1.25))
        h.track(CGPoint(x: 0, y: 0), at: 1.1, inside: true)
        XCTAssertFalse(h.shouldClose(at: 2))
    }

    func testHeldModifierSuppressesOpening() {
        var h = HoverIntent(openDelay: 0.12)
        h.track(.zero, at: 0, inside: true, suppressed: true)
        h.track(.zero, at: 0.5, inside: true, suppressed: true)
        XCTAssertFalse(h.shouldOpen(at: 0.55))
        XCTAssertTrue(h.shouldOpen(at: 0.62))
    }
}

final class NowPlayingTests: XCTestCase {
    func line(_ json: String) -> Data { Data(json.utf8) }

    func testFullPayloadThenDiffs() throws {
        var s = AdapterStreamState()
        let full = s.apply(line: line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","playing":true,"title":"Midnight City","artist":"M83","durationMicros":243000000,"elapsedTimeMicros":60000000,"timestampEpochMicros":1700000000000000,"playbackRate":1,"artworkData":"AAAA"}}"#))
        XCTAssertEqual(full?.info?.title, "Midnight City")
        XCTAssertEqual(full?.info?.duration, 243)
        XCTAssertEqual(full?.artworkChanged, true)
        XCTAssertEqual(full?.artwork, "AAAA")

        let pause = s.apply(line: line(#"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0}}"#))
        XCTAssertEqual(pause?.info?.isPlaying, false)
        XCTAssertEqual(pause?.info?.artist, "M83", "diff keeps untouched keys")
        XCTAssertEqual(pause?.artworkChanged, false)

        let gone = s.apply(line: line(#"{"type":"data","diff":true,"payload":{"artworkData":null}}"#))
        XCTAssertEqual(gone?.artworkChanged, true)
        XCTAssertNil(gone?.artwork, "null removes a key")

        let empty = s.apply(line: line(#"{"type":"data","diff":false,"payload":{}}"#))
        XCTAssertNotNil(empty)
        XCTAssertNil(empty?.info, "nothing playing")
        XCTAssertNil(s.apply(line: line("not json")))
    }

    func testPlayheadIsInterpolatedLocally() {
        let ts = Date(timeIntervalSince1970: 100)
        var i = NowPlayingInfo(bundleID: "x", title: "t", duration: 200, elapsed: 50, timestamp: ts, playbackRate: 1, isPlaying: true)
        XCTAssertEqual(i.position(at: ts + 10), 60)
        XCTAssertEqual(i.position(at: ts + 1000), 200, "clamped to duration")
        i.isPlaying = false
        XCTAssertEqual(i.position(at: ts + 10), 50, "paused does not advance")
        i.isPlaying = true; i.playbackRate = 2
        XCTAssertEqual(i.position(at: ts + 10), 70)
    }

    func testLineBufferSplitsAcrossChunks() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(b.append(Data("1}\n{\"b\":2}\n\n{\"c\"".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"a":1}"#, #"{"b":2}"#])
    }
}

final class UtilityTests: XCTestCase {
    func testDeepLinks() {
        XCTAssertEqual(DeepLink(url: URL(string: "notchy://timer?minutes=5")!), .startTimer(300))
        XCTAssertEqual(DeepLink(url: URL(string: "notchy://timer?seconds=90")!), .startTimer(90))
        XCTAssertEqual(DeepLink(url: URL(string: "notchy://timer/cancel")!), .cancelTimer)
        XCTAssertNil(DeepLink(url: URL(string: "notchy://timer")!))
        XCTAssertEqual(DeepLink(url: URL(string: "notchy://update")!), .update)
        XCTAssertNil(DeepLink(url: URL(string: "https://timer?minutes=5")!))
    }

    func testDeepLinksRejectOrClampHostileNumbers() {
        XCTAssertNil(DeepLink(url: URL(string: "notchy://timer?minutes=nan")!))
        XCTAssertNil(DeepLink(url: URL(string: "notchy://timer?minutes=-5")!))
        XCTAssertNil(DeepLink(url: URL(string: "notchy://timer?minutes=inf&seconds=-inf")!))
        XCTAssertEqual(DeepLink(url: URL(string: "notchy://timer?minutes=1e308")!), .startTimer(24 * 3600))
        XCTAssertEqual(DeepLink(url: URL(string: "notchy://timer?seconds=inf")!), .startTimer(24 * 3600))
        XCTAssertNil(DeepLink(url: URL(string: "notchy://unknown")!))
    }

    func testMeetingLinksIgnoreLookalikesAndOtherSchemes() {
        for text in ["https://zoom.us.evil.example/j/1", "https://zoom.us@evil.example/j/1", "https://evilzoom.us/j/1",
                     "https://zoom.us:8443/j/1", "javascript:alert(1)//zoom.us/", "file:///zoom.us/j/1", "smb://zoom.us/j/1"] {
            XCTAssertNil(MeetingLink.find(in: [text]), text)
        }
        // Only the real host is ever returned, even when it appears inside another URL.
        XCTAssertEqual(MeetingLink.find(in: ["https://evil.example/?next=https://zoom.us/j/1"])?.host, "zoom.us")
    }

    func testSpotifyArtworkOnlyFromItsCDNOverHTTPS() {
        XCTAssertNotNil(SpotifyArtwork.url("https://i.scdn.co/image/ab67616d0000b273"))
        XCTAssertNotNil(SpotifyArtwork.url("https://image-cdn-ak.spotifycdn.com/image/ab67"))
        for s in ["http://i.scdn.co/image/1", "file:///etc/hosts", "https://i.scdn.co.evil.example/1",
                  "https://evil.example/i.scdn.co", "ftp://i.scdn.co/1", "not a url"] {
            XCTAssertNil(SpotifyArtwork.url(s), s)
        }
    }

    func testMeetingLinks() {
        XCTAssertEqual(MeetingLink.find(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123?pwd=abc thanks"])?.absoluteString,
                       "https://us02web.zoom.us/j/123?pwd=abc")
        XCTAssertEqual(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.host, "meet.google.com")
        XCTAssertNil(MeetingLink.find(in: ["https://example.com/zoom.us/j/1"]))
    }

    func testTintPrefersSaturatedHueAndReadsOnBlack() {
        // Mostly dark grey with a patch of deep blue: expect a lifted blue.
        var px: [UInt8] = []
        for i in 0..<64 { px += i < 16 ? [20, 40, 120, 255] : [30, 30, 30, 255] }
        let c = ArtworkTint.dominant(rgba: px)
        XCTAssertGreaterThan(c.b, c.r)
        XCTAssertGreaterThanOrEqual(max(c.r, c.g, c.b), 0.8)
        XCTAssertTrue(ArtworkTint.dominant(rgba: [UInt8](repeating: 128, count: 256)) == ArtworkTint.neutral)
        XCTAssertEqual(formatDuration(65), "1:05")
        XCTAssertEqual(formatDuration(3723), "1:02:03")
    }
}
