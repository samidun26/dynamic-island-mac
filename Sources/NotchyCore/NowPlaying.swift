import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct NowPlayingInfo: Equatable, Sendable {
    public var bundleID: String
    /// Set for web media: the browser that owns the playing tab.
    public var parentBundleID: String?
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?
    /// Playhead at `timestamp`.
    public var elapsed: TimeInterval?
    public var timestamp: Date?
    public var playbackRate: Double
    public var isPlaying: Bool

    public init(bundleID: String, parentBundleID: String? = nil, title: String, artist: String = "", album: String = "",
                duration: TimeInterval? = nil, elapsed: TimeInterval? = nil, timestamp: Date? = nil,
                playbackRate: Double = 1, isPlaying: Bool) {
        self.bundleID = bundleID
        self.parentBundleID = parentBundleID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
    }

    /// Identifies the track (not its playback state); a change triggers the peek.
    public var trackKey: String { [bundleID, title, artist, album].joined(separator: "\u{1}") }

    /// The app whose icon to show.
    public var sourceBundleID: String { parentBundleID ?? bundleID }

    /// Playhead interpolated locally from the last report. Never poll for position.
    public func position(at date: Date) -> TimeInterval? {
        guard let e = elapsed else { return nil }
        var p = e
        if isPlaying, let ts = timestamp {
            let rate = playbackRate > 0 ? playbackRate : 1
            p += rate * date.timeIntervalSince(ts)
        }
        if let d = duration, d > 0 { p = min(p, d) }
        return max(0, p)
    }

    public func progress(at date: Date) -> Double {
        guard let d = duration, d > 0, let p = position(at: date) else { return 0 }
        return min(1, max(0, p / d))
    }
}

/// Folds the JSON lines of `mediaremote-adapter.pl … stream --micros` (full payloads and diffs)
/// into the current state. Not thread-safe: use from one queue.
public struct AdapterStreamState {
    public struct Update: Sendable {
        public var info: NowPlayingInfo?
        /// The artwork changed with this line (diffs only carry it when it changes).
        public var artworkChanged: Bool
        /// Current base64 artwork, if any.
        public var artwork: String?
    }

    public private(set) var payload: [String: Any] = [:]

    public init() {}

    /// Returns nil for lines that are not data messages.
    public mutating func apply(line: Data) -> Update? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "data",
              let p = obj["payload"] as? [String: Any] else { return nil }
        let isDiff = (obj["diff"] as? Bool) ?? false
        if isDiff {
            for (k, v) in p {
                if v is NSNull { payload.removeValue(forKey: k) } else { payload[k] = v }
            }
        } else {
            payload = p
        }
        return Update(info: info,
                      artworkChanged: !isDiff || p.keys.contains("artworkData"),
                      artwork: payload["artworkData"] as? String)
    }

    public var info: NowPlayingInfo? {
        guard let bundle = payload["bundleIdentifier"] as? String,
              let title = payload["title"] as? String, !title.isEmpty else { return nil }
        func num(_ k: String) -> Double? { (payload[k] as? NSNumber)?.doubleValue }
        let duration = num("durationMicros").map { $0 / 1e6 } ?? num("duration")
        let elapsed = num("elapsedTimeMicros").map { $0 / 1e6 } ?? num("elapsedTime")
        let ts = num("timestampEpochMicros").map { Date(timeIntervalSince1970: $0 / 1e6) }
        return NowPlayingInfo(
            bundleID: bundle,
            parentBundleID: payload["parentApplicationBundleIdentifier"] as? String,
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            duration: duration.flatMap { $0 > 0 ? $0 : nil },
            elapsed: elapsed,
            timestamp: ts,
            playbackRate: num("playbackRate") ?? 1,
            isPlaying: (payload["playing"] as? Bool) ?? false
        )
    }
}

/// Splits a byte stream into lines. Artwork lines can be hundreds of KB.
public struct LineBuffer: Sendable {
    private var pending = Data()
    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}
