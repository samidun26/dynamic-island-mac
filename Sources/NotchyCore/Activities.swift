import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum ActivityKind: String, CaseIterable, Sendable, Hashable {
    case hud, battery, timer, calendar, nowPlaying
}

/// What the island is doing. The view and the window derive everything from this.
public enum IslandState: Equatable, Sendable {
    case idle
    case compact(ActivityKind)
    case expanded(Page)
    /// Auto-expanded for a few seconds (track change, timer done, event alert).
    case peek(ActivityKind)

    public var isOpen: Bool {
        switch self {
        case .expanded, .peek: true
        case .idle, .compact: false
        }
    }

    public var isCompact: Bool {
        if case .compact = self { return true }
        return false
    }
}

/// A page in the expanded island. `home` (clock, next event, quick timers) is always last.
public enum Page: Hashable, Sendable {
    case activity(ActivityKind)
    case home
}

public struct ActivityEntry: Equatable, Sendable {
    public var kind: ActivityKind
    /// Higher wins. See `ActivityPriority`.
    public var priority: Int
    /// HUDs and plug-in banners: always shown first and never cycled away.
    public var transient: Bool
    /// Occupies the compact wings (e.g. Now Playing only while playing).
    public var showsCompact: Bool
    /// Has an expanded page.
    public var hasPage: Bool
    /// When it started; newer wins ties.
    public var since: Date

    public init(kind: ActivityKind, priority: Int, transient: Bool = false, showsCompact: Bool = true, hasPage: Bool = true, since: Date) {
        self.kind = kind
        self.priority = priority
        self.transient = transient
        self.showsCompact = showsCompact
        self.hasPage = hasPage
        self.since = since
    }
}

public enum ActivityPriority {
    public static let hud = 100
    public static let timerDone = 90
    public static let eventImminent = 80
    public static let battery = 70
    public static let timer = 60
    public static let nowPlaying = 50
    public static let eventSoon = 30
    public static let background = 10
}

/// Picks which activity owns the compact slots, like the iPhone's Dynamic Island.
/// The rest show as minimal glyphs and can be cycled with a horizontal swipe.
public struct ActivityQueue: Equatable, Sendable {
    public var entries: [ActivityEntry]
    /// Set by a swipe: the user wants this one in front (transients still win).
    public var preferred: ActivityKind?

    public init(entries: [ActivityEntry], preferred: ActivityKind? = nil) {
        self.entries = entries
        self.preferred = preferred
    }

    private func ranked(_ list: [ActivityEntry]) -> [ActivityEntry] {
        list.sorted { a, b in
            if a.transient != b.transient { return a.transient }
            if !a.transient, let p = preferred, (a.kind == p) != (b.kind == p) { return a.kind == p }
            if a.priority != b.priority { return a.priority > b.priority }
            if a.since != b.since { return a.since > b.since }
            return a.kind.rawValue < b.kind.rawValue
        }
    }

    /// Compact-capable activities, best first.
    public var compactOrder: [ActivityKind] {
        ranked(entries.filter(\.showsCompact)).map(\.kind)
    }

    public var primary: ActivityKind? { compactOrder.first }

    /// Shown as minimal glyphs next to the primary's trailing content. Transients never
    /// appear here: they are momentary and only ever take over the whole island.
    public var secondaries: [ActivityKind] {
        let transients = Set(entries.filter(\.transient).map(\.kind))
        // A HUD or banner takes the whole island for its moment.
        if let p = primary, transients.contains(p) { return [] }
        return compactOrder.dropFirst().filter { !transients.contains($0) }
    }

    /// Expanded pages in display order, `home` last.
    public var pages: [Page] {
        ranked(entries.filter { $0.hasPage && !$0.transient }).map { .activity($0.kind) } + [.home]
    }

    /// Next non-transient compact activity after the current primary, wrapping around.
    public func cycled(by step: Int) -> ActivityKind? {
        let order = ranked(entries.filter { $0.showsCompact && !$0.transient }).map(\.kind)
        guard !order.isEmpty else { return nil }
        let current = order.firstIndex(of: primary ?? order[0]) ?? 0
        let n = order.count
        return order[((current + step) % n + n) % n]
    }
}
