import AppKit
import ApplicationServices
import NotchyCore
import Observation

/// How much of the menu bar beside the notch is free, so the compact wings never cover a menu
/// title or a menu bar icon.
///  - Right: menu bar icons are ordinary windows at the status level; their frames are public.
///  - Left: the app menus belong to the frontmost app; seeing where they end needs Accessibility.
/// Measured off the main thread when the frontmost app or the screen changes, and every two
/// seconds while a compact activity is on screen (icons come and go, menus change).
@MainActor @Observable
final class MenuBarSpace {
    private(set) var clearance = MenuBarClearance.unlimited
    /// Whether the left side (the app menus) can be seen.
    private(set) var seesMenus = false

    @ObservationIgnored private var metrics: NotchMetrics?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var measuring = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private let queue = DispatchQueue(label: "notchy.menubar", qos: .utility)

    func start(metrics: NotchMetrics) {
        self.metrics = metrics
        guard observers.isEmpty else { return measure() }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // The new app's menus are in place a moment after it activates.
            MainActor.assumeIsolated { self?.measure(after: 0.15) }
        })
        measure()
    }

    /// Demos and snapshots: a made-up menu bar.
    func showDemo(_ c: MenuBarClearance) {
        clearance = c
        seesMenus = c.left != nil
    }

    /// Ask for Accessibility, which lets Notchy see where the frontmost app's menus end.
    func requestAccess() {
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        // Granting it doesn't notify the app: look again for a while.
        for delay in [2.0, 5, 10, 20, 40] { measure(after: delay) }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        setWatching(false)
        clearance = .unlimited
    }

    func update(metrics: NotchMetrics) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
        if !observers.isEmpty { measure() }
    }

    /// Keep measuring while a compact activity is on screen.
    func setWatching(_ on: Bool) {
        guard on != (timer != nil), !observers.isEmpty || !on else { return }
        timer?.invalidate()
        timer = nil
        guard on else { return }
        measure()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
        timer?.tolerance = 0.5
    }

    private func measure(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.measure()
        }
    }

    func measure() {
        guard let m = metrics else { return }
        guard !measuring else { again = true; return }
        measuring = true
        let input = Input(notch: m.notchRect, screen: m.screenFrame, hasNotch: m.hasNotch,
                          primaryHeight: NSScreen.screens.first?.frame.height ?? m.screenFrame.maxY,
                          screens: NSScreen.screens.map(\.frame),
                          menuOwner: NSWorkspace.shared.menuBarOwningApplication?.processIdentifier,
                          previousLeft: clearance == .unlimited ? nil : clearance.left)
        queue.async { [weak self] in
            let result = Self.measure(input)
            Task { @MainActor in
                guard let self else { return }
                self.measuring = false
                self.seesMenus = result.left != nil
                if result != self.clearance {
                    self.clearance = result
                    QALog.log("MENUBAR left=\(result.left.map { "\(Int($0))" } ?? "unknown") right=\(Int(result.right))")
                }
                if self.again {
                    self.again = false
                    self.measure()
                }
            }
        }
    }

    // MARK: Measuring (off the main thread)

    struct Input: Sendable {
        var notch: CGRect           // AppKit coordinates
        var screen: CGRect
        var hasNotch: Bool
        var primaryHeight: CGFloat
        var screens: [CGRect]
        var menuOwner: pid_t?
        var previousLeft: CGFloat?
    }

    nonisolated static func measure(_ i: Input) -> MenuBarClearance {
        // Window and accessibility frames use a top-left origin on the primary display.
        let top = i.primaryHeight - i.screen.maxY
        let band = (top - 1)...(top + max(i.notch.height, 24) + 4)

        // Right: menu bar icons, whoever owns them (Control Center, other apps, Notchy's own).
        var right = i.screen.maxX - i.notch.maxX
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == statusLevel {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d as CFDictionary),
                  band.contains(r.midY), r.width < 400, r.maxX <= i.screen.maxX + 1 else { continue }
            // Behind a real notch an icon is hidden by macOS, not covered by the island. Without a
            // notch it is visible wherever it is, even where the fake notch would be drawn.
            guard i.hasNotch ? r.minX >= i.notch.maxX - 2 : r.maxX > i.notch.minX else { continue }
            right = min(right, r.minX - i.notch.maxX)
        }

        // Left: where the frontmost app's menus end. Menus are laid out from the left edge of each
        // display, so measure relative to the display they are on.
        var left: CGFloat?
        // Notchy never shows menus of its own (the menu bar keeps the previous app's), so it is
        // never asked about itself.
        if AXIsProcessTrusted(), let pid = i.menuOwner, pid != getpid() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            let notchStart = i.notch.minX - i.screen.minX
            var end: CGFloat = 0
            var found = false
            for item in children(attribute(app, kAXMenuBarAttribute)) {
                guard let r = frame(item), r.width > 0,
                      let display = i.screens.first(where: { $0.minX <= r.minX && r.minX < $0.maxX }) else { continue }
                let start = r.minX - display.minX
                if i.hasNotch {
                    // Menus that don't fit before the notch are hidden by macOS; they don't count.
                    guard start < notchStart else { continue }
                    end = max(end, min(r.maxX - display.minX, notchStart))
                } else {
                    end = max(end, r.maxX - display.minX)
                }
                found = true
            }
            // No menus yet (an app that is still activating): keep what was there.
            left = found ? notchStart - end : i.previousLeft
        } else if AXIsProcessTrusted() {
            left = i.previousLeft
        }
        // Negative only without a notch: something sits where the fake notch would be drawn.
        return i.hasNotch ? MenuBarClearance(left: left.map { max(0, $0) }, right: max(0, right))
                          : MenuBarClearance(left: left, right: right)
    }

    private nonisolated static func attribute(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private nonisolated static func children(_ e: AXUIElement?) -> [AXUIElement] {
        guard let e else { return [] }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private nonisolated static func frame(_ e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}
