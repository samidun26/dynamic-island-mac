import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Free menu bar width on each side of the notch: from the notch's edge to the nearest app menu
/// (left) or menu bar icon (right). Negative on a display without a notch when a menu or an icon
/// sits where the fake notch would be drawn.
public struct MenuBarClearance: Equatable, Sendable {
    /// `nil` when it can't be seen: reading where another app's menus end needs Accessibility.
    public var left: CGFloat?
    public var right: CGFloat

    public init(left: CGFloat?, right: CGFloat) {
        self.left = left
        self.right = right
    }

    /// Not measured, or the user lets the wings cover the menu bar: everything counts as free.
    public static let unlimited = MenuBarClearance(left: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude)
}

/// How a compact live activity sits beside the notch without covering menu bar items.
public struct WingFit: Equatable, Sendable {
    public enum Arrangement: String, Equatable, Sendable {
        /// The usual look: leading content left of the notch, trailing content right of it.
        case split
        /// Both on the right: the left side is taken, or can't be seen.
        case right
        /// Both on the left: the right side is taken.
        case left
        /// No room either side: a slim lip under the notch shows the activity's progress.
        case folded
        /// Displays without a notch only: something sits where the fake notch would be drawn, so
        /// nothing is drawn. Hovering there still opens the island.
        case hidden
    }

    public var arrangement: Arrangement
    public var left: CGFloat
    public var right: CGFloat

    public init(arrangement: Arrangement, left: CGFloat, right: CGFloat) {
        self.arrangement = arrangement
        self.left = left
        self.right = right
    }

    /// Space kept between the island and the nearest menu bar item.
    public static let gap: CGFloat = 6

    /// - Parameters:
    ///   - wing: preferred width of each wing.
    ///   - minWing: the narrowest a wing can be and still show its content.
    ///   - single: the width that fits both pieces of content on one side.
    ///   - clearance: free menu bar width each side of the notch. An unknown left side counts
    ///     as taken: the island never covers menus it can't see.
    public static func fit(wing: CGFloat, minWing: CGFloat, single: CGFloat, clearance: MenuBarClearance) -> WingFit {
        if (clearance.left ?? 0) < 0 || clearance.right < 0 {
            return WingFit(arrangement: .hidden, left: 0, right: 0)
        }
        let l = (clearance.left ?? 0) - gap
        let r = clearance.right - gap
        if l >= minWing, r >= minWing {
            // Equal wings keep the island centred on the notch.
            let w = min(wing, l, r)
            return WingFit(arrangement: .split, left: w, right: w)
        }
        if r >= single { return WingFit(arrangement: .right, left: 0, right: single) }
        if l >= single { return WingFit(arrangement: .left, left: single, right: 0) }
        return WingFit(arrangement: .folded, left: 0, right: 0)
    }
}
