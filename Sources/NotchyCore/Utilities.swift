import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// `notchy://` URLs, usable from Shortcuts ("Open URL"), Terminal (`open notchy://…`) or scripts.
public enum DeepLink: Equatable, Sendable {
    case startTimer(TimeInterval)
    case cancelTimer
    case open
    case settings
    case update

    /// notchy://timer?minutes=5, notchy://timer?seconds=90, notchy://timer/cancel,
    /// notchy://open, notchy://settings, notchy://update (shows the update section and checks)
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "notchy" else { return nil }
        let host = url.host?.lowercased() ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> Double? { items.first { $0.name == name }?.value.flatMap(Double.init) }
        switch host {
        case "timer":
            if url.path.lowercased().contains("cancel") || items.contains(where: { $0.name == "action" && $0.value == "cancel" }) {
                self = .cancelTimer
                return
            }
            let seconds = (value("minutes").map { $0 * 60 } ?? 0) + (value("seconds") ?? 0)
            guard seconds >= 1 else { return nil }
            self = .startTimer(min(seconds, 24 * 3600))
        case "open", "expand": self = .open
        case "settings", "preferences": self = .settings
        case "update", "updates": self = .update
        default: return nil
        }
    }
}

/// Finds a video-call link in an event's URL, location or notes.
public enum MeetingLink {
    // Immutable after creation, safe to share.
    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        pattern: #"https?://(?:[A-Za-z0-9-]+\.)*(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|meet\.jit\.si|facetime\.apple\.com|around\.co)/[^\s<>"')]*"#,
        options: [.caseInsensitive]
    )

    public static func find(in texts: [String?]) -> URL? {
        for case let text? in texts {
            let range = NSRange(text.startIndex..., in: text)
            if let m = pattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }
}

/// Spotify's AppleScript reports album art as a URL. It is fetched only over HTTPS from Spotify's
/// image CDN; anything else (plain HTTP, file URLs, other hosts) is ignored.
public enum SpotifyArtwork {
    public static func url(_ s: String) -> URL? {
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "i.scdn.co" || host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com") else { return nil }
        return url
    }
}

/// The step response of a damped spring with SwiftUI's `response`/`dampingFraction`
/// parameters. Used for the snapshot filmstrips and to know when an animation has settled.
public struct SpringCurve: Equatable, Sendable {
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    public func value(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / max(response, 0.01)
        let z = min(max(dampingFraction, 0), 1)
        if z >= 0.999 {
            return 1 - exp(-w0 * t) * (1 + w0 * t)
        }
        let wd = w0 * (1 - z * z).squareRoot()
        return 1 - exp(-z * w0 * t) * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))
    }

    /// Time after which the curve stays within 0.5% of its target.
    public var settlingTime: Double {
        var t = 2.0
        while t > 0, abs(value(at: t) - 1) < 0.005 { t -= 0.01 }
        return t + 0.01
    }
}

/// Picks an accent colour from album art: the most common saturated hue, lifted so it reads
/// on black. Input is RGBA8 pixels (a small downsample is enough).
public enum ArtworkTint {
    public static let neutral = (r: 0.86, g: 0.86, b: 0.88)

    public static func dominant(rgba: [UInt8]) -> (r: Double, g: Double, b: Double) {
        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var i = 0
        while i + 3 < rgba.count {
            let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
            i += 4
            let (h, s, v) = hsv(r, g, b)
            guard s > 0.2, v > 0.18 else { continue }
            let w = s * s * min(1, v * 1.4)
            let bin = min(bins - 1, Int(h * Double(bins)))
            weight[bin] += w
            sum[bin].0 += r * w; sum[bin].1 += g * w; sum[bin].2 += b * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0.5 else { return neutral }
        let w = weight[best]
        let (h, s, v) = hsv(sum[best].0 / w, sum[best].1 / w, sum[best].2 / w)
        return rgb(h, min(s, 0.85), max(v, 0.82))
    }

    public static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    public static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

/// "4:05", "1:02:03"
public func formatDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
