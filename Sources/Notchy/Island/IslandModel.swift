import AppKit
import NotchyCore
import Observation
import SwiftUI

enum SwipeDirection { case left, right, up, down }

/// The island's single source of truth.
///
/// Inputs (hover, pin, peek, the activity models, settings) are plain observed properties.
/// `refresh()` derives the presentation (`state`, `geometry`, `secondaries`, `pages`) from them
/// and commits it inside one spring transaction, so the shape, its clip and the content
/// transitions always animate together. It re-runs whenever anything it read changes.
@MainActor @Observable
final class IslandModel {
    let settings: AppSettings
    let nowPlaying = NowPlayingModel()
    let timer = TimerModel()
    let battery = BatteryModel()
    let calendar = CalendarModel()
    let hud = HUDModel()
    let menuBar = MenuBarSpace()
    let shelf: ShelfModel
    let clipboard: ClipboardModel

    var metrics: NotchMetrics {
        didSet { menuBar.update(metrics: metrics) }
    }

    // Presentation (derived)
    private(set) var state = IslandState.idle
    private(set) var geometry: IslandGeometry
    private(set) var secondaries: [ActivityKind] = []
    /// How the compact activity sits beside the notch (see `fit(for:secondaries:)`).
    private(set) var compactFit = WingFit(arrangement: .split, left: 0, right: 0)
    private(set) var pages: [Page] = [.home]
    /// +1 when the last page change moved forward, -1 backward (drives the slide direction).
    private(set) var pageDirection = 1

    // Interaction inputs
    private(set) var hoverOpen = false
    private(set) var pinned = false
    private(set) var hovering = false
    private(set) var peekKind: ActivityKind?
    /// Files are being dragged near the notch: the island opens on the shelf to take them.
    private(set) var fileDragNear = false
    /// …and are over the island, where letting go drops them on the shelf.
    private(set) var dropTargeted = false
    /// Which half of the shelf is showing.
    var shelfTab = ShelfTab.files
    private(set) var selectedPage: Page?
    private(set) var preferred: ActivityKind?

    /// Called after a committed change (window click-through, haptics).
    @ObservationIgnored var onPresentationChange: ((_ old: IslandState, _ new: IslandState) -> Void)?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(settings: AppSettings, metrics: NotchMetrics) {
        self.settings = settings
        self.metrics = metrics
        shelf = ShelfModel(persists: settings.persists)
        clipboard = ClipboardModel(persists: settings.persists)
        geometry = metrics.idle(hidden: !metrics.hasNotch)
        nowPlaying.onTrackChange = { [weak self] _ in
            guard let self, self.settings.peekOnTrackChange else { return }
            self.peek(.nowPlaying, seconds: 3)
        }
        timer.onFinish = { [weak self] in
            QALog.log("TIMER done")
            self?.peek(.timer, seconds: 6)
        }
        timer.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            QALog.log("POMODORO \(phase.title(rounds: self.timer.pomodoro?.plan.rounds ?? 4))")
            self.peek(.timer, seconds: 4)
        }
        calendar.onAlert = { [weak self] _ in self?.peek(.calendar, seconds: 6) }
        refresh()
    }

    // MARK: Derivation

    struct Presentation: Equatable {
        var state: IslandState
        var geometry: IslandGeometry
        var secondaries: [ActivityKind]
        var fit: WingFit
        var pages: [Page]
    }

    /// System Settings > Accessibility > Display > Reduce motion: crossfades instead of springs.
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var openSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: settings.openResponse, dampingFraction: settings.openDamping)
    }
    var closeSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: settings.closeResponse, dampingFraction: settings.closeDamping)
    }

    func refresh() {
        generation += 1
        let gen = generation
        let next = withObservationTracking { derive() } onChange: { [weak self] in
            // Fires before the value changes; re-derive on the next turn with the new values.
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.refresh()
            }
        }
        commit(next)
    }

    private func commit(_ next: Presentation) {
        let current = Presentation(state: state, geometry: geometry, secondaries: secondaries, fit: compactFit, pages: pages)
        guard next != current else { return }
        let area = { (g: IslandGeometry) in g.size.width * g.size.height }
        let growing = area(next.geometry) >= area(current.geometry)
        let old = state
        withAnimation(growing ? openSpring : closeSpring) {
            state = next.state
            geometry = next.geometry
            secondaries = next.secondaries
            compactFit = next.fit
            pages = next.pages
        }
        let fit = next.state.isCompact ? " fit=\(next.fit.arrangement.rawValue):\(Int(next.fit.left))/\(Int(next.fit.right)) x=\(Int(metrics.islandRect(next.geometry).minX - metrics.screenFrame.minX))" : ""
        QALog.log("STATE \(QALog.describe(next.state)) \(Int(next.geometry.size.width))x\(Int(next.geometry.size.height)) secondaries=\(next.secondaries.map(\.rawValue)) pages=\(next.pages.count)\(fit)")
        menuBar.setWatching(next.state.isCompact)
        onPresentationChange?(old, next.state)
    }

    func activityEntries() -> [ActivityEntry] {
        var e: [ActivityEntry] = []
        let s = settings
        if s.hudEnabled, let h = hud.current {
            e.append(ActivityEntry(kind: .hud, priority: ActivityPriority.hud, transient: true, hasPage: false, since: h.at))
        }
        if s.batteryEnabled, let b = battery.banner {
            e.append(ActivityEntry(kind: .battery, priority: ActivityPriority.battery, transient: true, hasPage: false, since: b.at))
        }
        if s.timerEnabled, timer.isActive {
            e.append(ActivityEntry(kind: .timer, priority: timer.isDone ? ActivityPriority.timerDone : ActivityPriority.timer, since: timer.startedAt))
        }
        if s.calendarEnabled {
            switch calendar.phase {
            case .imminent: e.append(ActivityEntry(kind: .calendar, priority: ActivityPriority.eventImminent, since: calendar.phaseSince))
            case .soon: e.append(ActivityEntry(kind: .calendar, priority: ActivityPriority.eventSoon, since: calendar.phaseSince))
            case .none: break
            }
        }
        if s.nowPlayingEnabled, nowPlaying.info != nil {
            e.append(ActivityEntry(kind: .nowPlaying, priority: ActivityPriority.nowPlaying, showsCompact: nowPlaying.isLive, since: nowPlaying.liveSince))
        }
        return e
    }

    private func derive() -> Presentation {
        let entries = activityEntries()
        let queue = ActivityQueue(entries: entries, preferred: preferred, shelf: settings.shelfEnabled)
        let pages = queue.pages
        let state: IslandState
        if fileDragNear || dropTargeted, settings.shelfEnabled {
            state = .expanded(.shelf)
        } else if hoverOpen || pinned {
            let page = selectedPage.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first ?? .home
            state = .expanded(page)
        } else if let p = peekKind, entries.contains(where: { $0.kind == p }) {
            state = .peek(p)
        } else if let k = queue.primary {
            state = .compact(k)
        } else {
            state = .idle
        }
        let secondaries = state.isOpen ? [] : Array(queue.secondaries.prefix(2))
        var fit = compactFit
        if case .compact(let kind) = state { fit = self.fit(for: kind, secondaries: secondaries.count) }
        return Presentation(state: state, geometry: layout(for: state, fit: fit), secondaries: secondaries, fit: fit, pages: pages)
    }

    /// Hidden when idle on screens without a notch, unless the user wants a permanent fake notch.
    var hidesWhenIdle: Bool { !metrics.hasNotch && settings.nonNotchMode != .always }

    private func layout(for state: IslandState, fit: WingFit) -> IslandGeometry {
        let bump = hovering && !settings.openOnHover
        // Fitted between menu bar items, the hover nudge only grows downward.
        let widen = !settings.keepClearOfMenuBar
        switch state {
        case .idle:
            if bump { return metrics.bumped(metrics.idle(), widen: widen) }
            return metrics.idle(hidden: hidesWhenIdle)
        case .compact:
            let g = switch fit.arrangement {
            case .folded: metrics.folded()
            case .hidden: metrics.idle(hidden: true)
            case .split, .left, .right: metrics.compact(left: fit.left, right: fit.right)
            }
            return bump && fit.arrangement != .hidden ? metrics.bumped(g, widen: widen) : g
        case .expanded, .peek:
            return metrics.expanded()
        }
    }

    static let minimalSlot: CGFloat = 22

    /// Where the compact activity goes so it covers no menu or menu bar icon: both wings when
    /// there is room, everything on one side when only one side is free, or a slim lip under the
    /// notch when neither is. With "Keep clear of the menu bar" off, it always uses both wings.
    func fit(for kind: ActivityKind, secondaries: Int) -> WingFit {
        let base = wing(for: kind)
        let extra = CGFloat(secondaries) * Self.minimalSlot
        let clearance = settings.keepClearOfMenuBar ? menuBar.clearance : .unlimited
        return WingFit.fit(wing: base + extra, minWing: (base * 0.78).rounded() + extra,
                           single: (base * 1.55).rounded() + extra, clearance: clearance)
    }

    /// Width of each compact wing for an activity, scaled to the notch height.
    func wing(for kind: ActivityKind) -> CGFloat {
        let h = metrics.notchSize.height
        switch kind {
        case .nowPlaying: return (h + 12).rounded()
        case .timer: return 64
        case .calendar: return 66
        case .hud: return 88
        case .battery: return 100
        }
    }

    // MARK: Interaction

    func setHovering(_ h: Bool) {
        if hovering != h { hovering = h }
    }

    func setHoverOpen(_ open: Bool) {
        guard hoverOpen != open else { return }
        hoverOpen = open
        if open {
            peekKind = nil
        } else if !pinned {
            selectedPage = nil
        }
    }

    /// Click on the island: open it and keep it open until a click elsewhere or a swipe up.
    func click() {
        QALog.log("PIN")
        pinned = true
        peekKind = nil
    }

    /// Opens the island on the shelf and keeps it open.
    func openShelf(_ tab: ShelfTab = .files) {
        guard settings.shelfEnabled else { return }
        shelfTab = tab
        select(.shelf)
        click()
    }

    func setFileDragNear(_ near: Bool) {
        guard fileDragNear != near else { return }
        fileDragNear = near
        QALog.log("DRAG files \(near ? "near" : "gone")")
        if near {
            selectedPage = .shelf
            shelfTab = .files
        }
    }

    func setDropTargeted(_ on: Bool) {
        guard dropTargeted != on else { return }
        dropTargeted = on
        QALog.log("DROP \(on ? "over" : "left")")
        if on {
            selectedPage = .shelf
            shelfTab = .files
        }
    }

    /// After a drop the shelf stays open to show what landed: until the pointer leaves, or in
    /// click-to-open mode until a click elsewhere.
    func droppedOnShelf(_ urls: [URL]) {
        shelf.add(urls)
        selectedPage = .shelf
        shelfTab = .files
        peekKind = nil
        if settings.openOnHover { hoverOpen = true } else { pinned = true }
    }

    func dismiss() {
        QALog.log("DISMISS")
        pinned = false
        hoverOpen = false
        peekKind = nil
        selectedPage = nil
    }

    func peek(_ kind: ActivityKind, seconds: Double) {
        guard !hoverOpen, !pinned else { return }
        peekKind = kind
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.peekKind == kind else { return }
            self.peekKind = nil
        }
    }

    func swipe(_ dir: SwipeDirection) {
        QALog.log("SWIPE \(dir)")
        switch dir {
        case .down:
            if !state.isOpen || peekKind != nil { click() }
        case .up:
            dismiss()
        case .left, .right:
            let step = dir == .left ? 1 : -1
            switch state {
            case .expanded(let page):
                guard let i = pages.firstIndex(of: page) else { return }
                let n = i + step
                guard pages.indices.contains(n) else { return }
                select(pages[n], direction: step)
            case .compact:
                preferred = ActivityQueue(entries: activityEntries(), preferred: preferred).cycled(by: step)
            case .idle, .peek:
                break
            }
        }
    }

    func select(_ page: Page, direction: Int? = nil) {
        if let direction {
            pageDirection = direction
        } else if case .expanded(let cur) = state, let a = pages.firstIndex(of: cur), let b = pages.firstIndex(of: page) {
            pageDirection = b >= a ? 1 : -1
        }
        selectedPage = page
    }

    // MARK: Services

    /// Starts and stops the activity sources to follow the settings.
    func startServices() {
        let s = settings
        observeChanges({ s.nowPlayingEnabled }) { [weak self] on in
            if on { self?.nowPlaying.start() } else { self?.nowPlaying.stop() }
        }
        observeChanges({ s.batteryEnabled }) { [weak self] on in
            if on { self?.battery.start() } else { self?.battery.stop() }
        }
        observeChanges({ s.calendarEnabled }) { [weak self] on in
            if on { self?.calendar.start() } else { self?.calendar.stop() }
        }
        observeChanges({ s.timerSound }) { [weak self] on in self?.timer.playSound = on }
        observeChanges({ s.brightnessEnabled }) { [weak self] on in self?.hud.setBrightnessEnabled(on) }
        observeChanges({ s.hudEnabled }) { [weak self] on in
            if on { self?.hud.enableKeys() } else { self?.hud.disableKeys() }
        }
        hud.startVolumeMirror()
        observeChanges({ s.clipboardHistory && s.shelfEnabled }) { [weak self] on in
            if on { self?.clipboard.start() } else { self?.clipboard.stop() }
        }
        observeChanges({ s.keepClearOfMenuBar }) { [weak self] on in
            guard let self else { return }
            if on { self.menuBar.start(metrics: self.metrics) } else { self.menuBar.stop() }
        }
    }
}

/// Calls `apply` with the current value of `read`, and again whenever an observed property that
/// `read` touched changes. Side effects stay out of the tracked closure.
@MainActor
func observeChanges<T>(_ read: @escaping @MainActor @Sendable () -> T, _ apply: @escaping @MainActor @Sendable (T) -> Void) {
    let value = withObservationTracking { read() } onChange: {
        Task { @MainActor in observeChanges(read, apply) }
    }
    apply(value)
}
