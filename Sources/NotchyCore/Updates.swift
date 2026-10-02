import Foundation

/// A dotted version number ("1.0.42", tags may start with "v"). Compares part by part, so
/// 1.0.10 > 1.0.9, and missing parts count as 0 (1.1 == 1.1.0).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        // Ignore pre-release or build suffixes ("1.2.0-beta", "1.2.0+5").
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into h: inout Hasher) {
        var p = parts
        while p.count > 1, p.last == 0 { p.removeLast() }
        h.combine(p)
    }
}

/// The newest published Notchy, as read from GitHub's "latest release" API.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    public var tag: String
    public var pageURL: URL
    public var notes: String
    public var zipURL: URL
    public var zipSize: Int
    public var checksumURL: URL?
}

public enum UpdateFeed {
    /// Where shipped builds look for updates.
    public static let defaultURL = URL(string: "https://api.github.com/repos/samidun26/dynamic-island-mac/releases/latest")!
    /// The release asset that holds the app, and its SHA-256 next to it.
    public static let zipName = "Notchy.zip"
    public static let checksumName = "Notchy.zip.sha256"
    /// Refuse anything bigger: the app is a few MB.
    public static let maxDownloadSize = 100 << 20

    /// A local test server (QA) or GitHub itself.
    public static func isLocal(_ url: URL) -> Bool {
        let h = url.host?.lowercased()
        return (url.scheme == "http" || url.scheme == "https") && (h == "127.0.0.1" || h == "localhost")
    }

    /// Updates come only from GitHub over HTTPS (release pages redirect downloads to
    /// *.githubusercontent.com). A local test feed may also serve its own downloads.
    public static func isTrustedSource(_ url: URL, localFeed: Bool) -> Bool {
        if localFeed, isLocal(url) { return true }
        guard url.scheme?.lowercased() == "https", let h = url.host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com" || h.hasSuffix(".githubusercontent.com")
    }

    /// Reads GitHub's release JSON. Nil for drafts, pre-releases, a tag that isn't a version,
    /// or a release without Notchy.zip from a trusted place.
    public static func parse(_ data: Data, localFeed: Bool = false) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["draft"] as? Bool) != true, (json["prerelease"] as? Bool) != true,
              let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(_ name: String) -> (URL, Int)? {
            guard let a = assets.first(where: { ($0["name"] as? String) == name }),
                  let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  isTrustedSource(url, localFeed: localFeed) else { return nil }
            return (url, (a["size"] as? Int) ?? 0)
        }
        guard let zip = asset(zipName), zip.1 <= maxDownloadSize else { return nil }
        return ReleaseInfo(version: version, tag: tag, pageURL: page, notes: json["body"] as? String ?? "",
                           zipURL: zip.0, zipSize: zip.1, checksumURL: asset(checksumName)?.0)
    }

    /// The hash in a `shasum -a 256` line ("<64 hex>  Notchy.zip"), lowercased.
    public static func checksum(in text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let hex = first.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}
