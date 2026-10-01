import Foundation

/// Everything the island shape animates: size plus corner radii.
/// `earRadius` is the small concave flare at the top corners that fuses the
/// black shape into the bezel; `bottomRadius` is the convex bottom corner.
public struct IslandGeometry: Equatable, Sendable {
    public var size: CGSize
    public var bottomRadius: CGFloat
    public var earRadius: CGFloat

    public init(size: CGSize, bottomRadius: CGFloat, earRadius: CGFloat) {
        self.size = size
        self.bottomRadius = bottomRadius
        self.earRadius = earRadius
    }

    public static func lerp(_ a: IslandGeometry, _ b: IslandGeometry, _ t: CGFloat) -> IslandGeometry {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return IslandGeometry(
            size: CGSize(width: mix(a.size.width, b.size.width), height: mix(a.size.height, b.size.height)),
            bottomRadius: mix(a.bottomRadius, b.bottomRadius),
            earRadius: mix(a.earRadius, b.earRadius)
        )
    }
}

/// Single source of truth for where the notch is and how big each island state is.
/// All rects are in AppKit global coordinates (origin bottom-left, y up).
public struct NotchMetrics: Equatable, Sendable {
    public var screenFrame: CGRect
    /// The physical notch, or a synthetic one on screens without a notch.
    public var notchRect: CGRect
    public var hasNotch: Bool

    // Layout constants. Expanded width grows the notch by a fixed amount each side.
    public static let expandedSideExtension: CGFloat = 150
    public static let expandedMinWidth: CGFloat = 470
    public static let expandedContentHeight: CGFloat = 128
    public static let shadowMargin: CGFloat = 36
    public static let hoverGrace: CGFloat = 12
    public static let syntheticNotchWidth: CGFloat = 184

    /// - Parameters:
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top` (0 without a notch).
    ///   - auxiliaryLeftWidth/RightWidth: widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
    ///   - menuBarHeight: height of the menu bar on this screen, used for the synthetic notch.
    public init(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?, menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        if safeAreaTop > 0, let l = auxiliaryLeftWidth, let r = auxiliaryRightWidth, screenFrame.width - l - r > 40 {
            // Notches are centred; derive the width from the two unobscured menu bar areas.
            let w = screenFrame.width - l - r
            notchRect = CGRect(x: screenFrame.minX + l, y: screenFrame.maxY - safeAreaTop, width: w, height: safeAreaTop)
            hasNotch = true
        } else {
            let h = max(menuBarHeight, 24).rounded() + 8
            let w = Self.syntheticNotchWidth
            notchRect = CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
            hasNotch = false
        }
    }

    public var notchSize: CGSize { notchRect.size }

    // MARK: State geometry

    /// Idle: exactly the notch so it is invisible. `hidden` collapses into the top edge
    /// (used on screens without a notch when nothing is happening).
    public func idle(hidden: Bool = false) -> IslandGeometry {
        if hidden {
            return IslandGeometry(size: CGSize(width: notchSize.width * 0.55, height: 0), bottomRadius: 0, earRadius: 0)
        }
        return IslandGeometry(size: notchSize, bottomRadius: min(10, notchSize.height * 0.32), earRadius: hasNotch ? 4 : 6)
    }

    /// Compact live activity: equal wings either side so the notch stays centred.
    public func compact(wing: CGFloat) -> IslandGeometry {
        let w = max(0, wing)
        return IslandGeometry(
            size: CGSize(width: notchSize.width + 2 * w, height: notchSize.height),
            bottomRadius: (notchSize.height * 0.42).rounded(),
            earRadius: 6
        )
    }

    /// Subtle grow on hover so the island feels touchable before it opens.
    public func bumped(_ g: IslandGeometry) -> IslandGeometry {
        var b = g
        b.size.width += 14
        b.size.height += 4
        b.bottomRadius += 2
        return b
    }

    public func expanded(contentHeight: CGFloat = NotchMetrics.expandedContentHeight) -> IslandGeometry {
        IslandGeometry(size: expandedSize(contentHeight: contentHeight), bottomRadius: 32, earRadius: 12)
    }

    public func expandedSize(contentHeight: CGFloat = NotchMetrics.expandedContentHeight) -> CGSize {
        CGSize(width: max(Self.expandedMinWidth, notchSize.width + 2 * Self.expandedSideExtension),
               height: notchSize.height + contentHeight)
    }

    // MARK: Window and hit testing

    /// The panel never resizes: it is sized once for the largest state plus room for the shadow
    /// and the ears.
    public var canvasSize: CGSize {
        let e = expandedSize()
        return CGSize(width: (e.width + 2 * Self.shadowMargin).rounded(.up),
                      height: (e.height + Self.shadowMargin).rounded(.up))
    }

    /// Panel frame: top-centre of the screen, flush with the top edge, centred on the notch.
    public var panelFrame: CGRect {
        let c = canvasSize
        return CGRect(x: (notchRect.midX - c.width / 2).rounded(), y: screenFrame.maxY - c.height, width: c.width, height: c.height)
    }

    /// Where the island body is on screen for a geometry.
    public func islandRect(_ g: IslandGeometry) -> CGRect {
        CGRect(x: notchRect.midX - g.size.width / 2, y: screenFrame.maxY - g.size.height,
               width: g.size.width, height: g.size.height)
    }

    /// Area that counts as "on the island". Never smaller than the notch, so a hidden island can
    /// still be summoned, and extended upward past the screen edge so the very top row counts.
    /// Use `grace: 0` for click-through and opening (menu bar items sit right next to the notch),
    /// and `hoverGrace` only to decide whether an open island should stay open.
    public func hitRect(_ g: IslandGeometry, grace: CGFloat = 0) -> CGRect {
        let body = islandRect(g).union(notchRect)
        return CGRect(x: body.minX - grace, y: body.minY - grace,
                      width: body.width + 2 * grace, height: body.height + grace + 4)
    }
}
