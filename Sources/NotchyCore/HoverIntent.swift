import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Decides when hovering should open or close the island.
///
/// - Opens only after the cursor has *dwelled* inside for `openDelay`. Moving faster than
///   `passThroughSpeed` restarts the dwell, so sweeping across the notch to reach the menu bar
///   never opens it.
/// - Closes `closeDelay` after leaving, unless the cursor comes back first.
/// - While a modifier or mouse button is held (`suppressed`) the dwell keeps restarting.
public struct HoverIntent: Sendable {
    public var openDelay: TimeInterval
    public var closeDelay: TimeInterval
    public var passThroughSpeed: CGFloat

    public private(set) var isInside = false
    private var dwellStart: TimeInterval?
    private var leftAt: TimeInterval?
    private var lastPoint: CGPoint?
    private var lastTime: TimeInterval?

    public init(openDelay: TimeInterval = 0.12, closeDelay: TimeInterval = 0.25, passThroughSpeed: CGFloat = 900) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
        self.passThroughSpeed = passThroughSpeed
    }

    public mutating func track(_ p: CGPoint, at t: TimeInterval, inside: Bool, suppressed: Bool = false) {
        var speed: CGFloat = 0
        if let lp = lastPoint, let lt = lastTime, t > lt, t - lt < 0.25 {
            let dx = p.x - lp.x, dy = p.y - lp.y
            speed = (dx * dx + dy * dy).squareRoot() / CGFloat(t - lt)
        }
        lastPoint = p
        lastTime = t

        if inside {
            if !isInside || suppressed || speed > passThroughSpeed || dwellStart == nil { dwellStart = t }
            leftAt = nil
        } else {
            if isInside || leftAt == nil { leftAt = t }
            dwellStart = nil
        }
        isInside = inside
    }

    /// When the dwell will have lasted long enough (schedule a check for then).
    public var openDeadline: TimeInterval? { dwellStart.map { $0 + openDelay } }
    public var closeDeadline: TimeInterval? { leftAt.map { $0 + closeDelay } }

    public func shouldOpen(at t: TimeInterval) -> Bool {
        guard isInside, let d = openDeadline else { return false }
        return t >= d - 0.001
    }

    public func shouldClose(at t: TimeInterval) -> Bool {
        guard !isInside, let d = closeDeadline else { return false }
        return t >= d - 0.001
    }

    public mutating func reset() {
        isInside = false
        dwellStart = nil
        leftAt = nil
        lastPoint = nil
        lastTime = nil
    }
}
