import AppKit
import NotchyCore
import SwiftUI

/// Borderless, transparent, non-activating panel that sits over the menu bar.
/// It is sized once (for the largest state) and never moves or resizes during animation.
final class IslandPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Borderless windows are normally pushed below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that takes the first click (the panel is never key) and never resizes its window.
final class IslandHostingView: NSHostingView<IslandRootView> {
    required init(rootView: IslandRootView) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Owns the panel and turns raw mouse/trackpad input into island intents.
///
/// Click-through: the panel ignores mouse events except while the pointer is over the island
/// itself, so the transparent canvas never blocks the menu bar or other apps. Hover uses
/// global + local mouse-moved monitors (tracking areas are unreliable for an inactive app and
/// stop working once the window ignores mouse events).
@MainActor
final class IslandController {
    let model: IslandModel
    let settings: AppSettings
    let panel: IslandPanel
    private(set) var screen: NSScreen?

    private var intent = HoverIntent()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var openCheck: Task<Void, Never>?
    private var closeCheck: Task<Void, Never>?
    private var scroll = CGSize.zero
    private var scrollFired = false
    /// Set when the island closes under the pointer (swipe up, peek ending): hovering must not
    /// reopen it until the pointer has left once.
    private var requireExit = false
    /// When hover last opened the island (system uptime).
    private var hoverOpenedAt: TimeInterval = -1
    private let demo: Bool

    init(model: IslandModel, settings: AppSettings, demo: Bool = false) {
        self.model = model
        self.settings = settings
        self.demo = demo
        panel = IslandPanel(frame: model.metrics.panelFrame)
        panel.contentView = IslandHostingView(rootView: IslandRootView(model: model))

        model.onPresentationChange = { [weak self] old, new in
            self?.presentationChanged(from: old, to: new)
        }
        relocate()
        installMonitors()
        installObservers()

        observeChanges({ [settings] in settings.hideFromScreenSharing }) { [weak self] hide in
            guard let self else { return }
            self.panel.sharingType = hide && !self.demo ? .none : .readOnly
        }
        observeChanges({ [settings] in (settings.screenChoice, settings.nonNotchMode) }) { [weak self] _ in
            self?.relocate()
        }
        observeChanges({ [settings] in settings.hoverDelay }) { [weak self] d in
            self?.intent.openDelay = d
        }
    }

    // MARK: Screens

    private func pickScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch settings.screenChoice {
        case .notched:
            return screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first
        case .primary:
            return screens.first
        case .mouse:
            let p = NSEvent.mouseLocation
            return screens.first { NSMouseInRect(p, $0.frame, false) } ?? screens.first
        }
    }

    static func metrics(for s: NSScreen) -> NotchMetrics {
        NotchMetrics(screenFrame: s.frame,
                     safeAreaTop: s.safeAreaInsets.top,
                     auxiliaryLeftWidth: s.auxiliaryTopLeftArea?.width,
                     auxiliaryRightWidth: s.auxiliaryTopRightArea?.width,
                     menuBarHeight: s.frame.maxY - s.visibleFrame.maxY)
    }

    /// Re-measure and re-pin the panel (screen change, settings change, hot-plug).
    func relocate(to target: NSScreen? = nil) {
        guard let s = target ?? pickScreen() else { return }
        screen = s
        let m = Self.metrics(for: s)
        if model.metrics != m { model.metrics = m }
        panel.setFrame(m.panelFrame, display: true)
        let hidden = !m.hasNotch && settings.nonNotchMode == .never
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        updateMouse(NSEvent.mouseLocation)
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relocate() }
            })
        }
    }

    // MARK: Mouse

    private func installMonitors() {
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(l) }

        // A click anywhere else dismisses a pinned island.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(g) }

        // Clicks and trackpad swipes on the island itself.
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel], handler: { [weak self] e in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, e.window === self.panel else { return false }
                if e.type == .scrollWheel { return self.handleScroll(e) }
                self.clickedIsland()
                return false
            }
            return consumed ? nil : e
        }) { monitors.append(l) }
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if settings.screenChoice == .mouse, !model.state.isOpen, let s = screen, !NSMouseInRect(p, s.frame, false),
           let other = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) {
            relocate(to: other)
        }
        updateMouse(p)
    }

    private func updateMouse(_ p: NSPoint) {
        let m = model.metrics
        let g = model.geometry
        // Only the visible body takes clicks. A hidden island (no notch, idle) never blocks the
        // menu bar, but resting on its spot still counts as hovering.
        let body = m.islandRect(g)
        let overBody = g.size.height > 0.5 && CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height + 4).contains(p)
        let overZone = m.hitRect(g).contains(p)
        // Far from the island with nothing pending: nothing to do.
        if !overZone && !intent.isInside && !model.hovering && panel.ignoresMouseEvents { return }

        if panel.ignoresMouseEvents == overBody {
            panel.ignoresMouseEvents = !overBody
            QALog.log("CLICKTHROUGH \(!overBody)")
        }
        model.setHovering(overZone)

        let open = model.state.isOpen
        let inside = open ? m.hitRect(g, grace: NotchMetrics.hoverGrace).contains(p) : overZone
        let held = !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty || NSEvent.pressedMouseButtons != 0
        if !inside { requireExit = false }
        intent.track(p, at: ProcessInfo.processInfo.systemUptime, inside: inside, suppressed: held && !open)
        scheduleHoverChecks()
    }

    private func scheduleHoverChecks() {
        openCheck?.cancel()
        closeCheck?.cancel()
        if settings.openOnHover, !requireExit, !model.state.isOpen || model.peekKind != nil, let deadline = intent.openDeadline {
            openCheck = after(deadline) { [weak self] in
                guard let self, self.intent.shouldOpen(at: ProcessInfo.processInfo.systemUptime) else { return }
                QALog.log("HOVER open")
                self.hoverOpenedAt = ProcessInfo.processInfo.systemUptime
                self.model.setHoverOpen(true)
            }
        }
        // Never close under a drag (scrubbing, volume) that wandered outside; re-checked on mouse up.
        if model.hoverOpen, NSEvent.pressedMouseButtons == 0, let deadline = intent.closeDeadline {
            closeCheck = after(deadline) { [weak self] in
                guard let self, self.intent.shouldClose(at: ProcessInfo.processInfo.systemUptime) else { return }
                QALog.log("HOVER close")
                self.model.setHoverOpen(false)
            }
        }
    }

    private func after(_ deadline: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            body()
        }
    }

    /// A click on a closed (or peeking) island opens and pins it. So does a click that lands just
    /// after hover opened it (the user was clicking to open; hover was simply faster). Later
    /// clicks on controls inside a hover-opened island leave it hover-managed.
    private func clickedIsland() {
        let p = NSEvent.mouseLocation
        guard model.metrics.hitRect(model.geometry).contains(p) else { return }
        let justHoverOpened = model.hoverOpen && ProcessInfo.processInfo.systemUptime - hoverOpenedAt < 0.4
        guard !model.state.isOpen || model.peekKind != nil || justHoverOpened, !model.pinned else { return }
        model.click()
    }

    private func clickedOutside() {
        guard model.state.isOpen, model.pinned || model.peekKind != nil else { return }
        if !model.metrics.hitRect(model.geometry).contains(NSEvent.mouseLocation) { model.dismiss() }
    }

    /// Two-finger swipes on the island: down opens, up closes, sideways switches activity/page.
    /// Returns true when the event was used.
    private func handleScroll(_ e: NSEvent) -> Bool {
        guard e.hasPreciseScrollingDeltas else { return false }
        if !e.momentumPhase.isEmpty { return true }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            scroll = .zero
            scrollFired = false
        }
        // Normalise to finger direction regardless of the "natural scrolling" setting.
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        scroll.width += e.scrollingDeltaX * sign
        scroll.height += e.scrollingDeltaY * sign
        if !scrollFired {
            let dx = scroll.width, dy = scroll.height
            if abs(dx) > 36, abs(dx) > abs(dy) * 1.4 {
                scrollFired = true
                model.swipe(dx < 0 ? .left : .right)
            } else if abs(dy) > 26, abs(dy) > abs(dx) * 1.4 {
                scrollFired = true
                model.swipe(dy > 0 ? .down : .up)
            }
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            scroll = .zero
            scrollFired = false
        }
        return true
    }

    // MARK: State changes

    private func presentationChanged(from old: IslandState, to new: IslandState) {
        if new.isOpen && !old.isOpen, settings.haptics, model.hoverOpen || model.pinned {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if old.isOpen && !new.isOpen {
            intent.reset()
            requireExit = model.metrics.hitRect(model.geometry).contains(NSEvent.mouseLocation)
        }
        // The island may have grown under a still pointer, or shrunk away from it.
        updateMouse(NSEvent.mouseLocation)
    }

    func tearDown() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        panel.orderOut(nil)
    }
}
