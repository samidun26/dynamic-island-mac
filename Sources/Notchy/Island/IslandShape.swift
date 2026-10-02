import SwiftUI
import NotchyCore

/// The island outline: a flat top flush with the screen edge, concave "ears" at the top corners
/// that flare into the bezel the way the physical notch does, and continuous convex bottom
/// corners. The body is top-aligned and centred horizontally (plus `offsetX`) in whatever rect it
/// is given, so the view's frame never has to change: width, height, both radii and the offset
/// animate as one value.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var earRadius: CGFloat
    var offsetX: CGFloat

    /// `centred` ignores the geometry's offset (for clipping content that is itself offset).
    init(_ g: IslandGeometry, centred: Bool = false) {
        width = g.size.width
        height = g.size.height
        bottomRadius = g.bottomRadius
        earRadius = g.earRadius
        offsetX = centred ? 0 : g.offsetX
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(AnimatablePair(bottomRadius, earRadius), offsetX)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            bottomRadius = newValue.second.first.first
            earRadius = newValue.second.first.second
            offsetX = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(0, width), h = max(0, height)
        guard w > 0.5, h > 0.5 else { return Path() }
        let x0 = rect.midX + offsetX - w / 2, x1 = rect.midX + offsetX + w / 2
        let y0 = rect.minY, y1 = rect.minY + h
        // Keep the corners inside the body however small it gets mid-animation.
        let r = max(0, min(bottomRadius, w / 2, h * 0.75))
        let e = max(0, min(earRadius, h - r, w / 4))
        // Bezier handle length for a circular quarter.
        let k: CGFloat = 0.5523

        var p = Path()
        p.move(to: CGPoint(x: x0 - e, y: y0))
        p.addLine(to: CGPoint(x: x1 + e, y: y0))
        if e > 0 { p.addQuadCurve(to: CGPoint(x: x1, y: y0 + e), control: CGPoint(x: x1, y: y0)) }
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addCurve(to: CGPoint(x: x1 - r, y: y1),
                   control1: CGPoint(x: x1, y: y1 - r + r * k),
                   control2: CGPoint(x: x1 - r + r * k, y: y1))
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addCurve(to: CGPoint(x: x0, y: y1 - r),
                   control1: CGPoint(x: x0 + r - r * k, y: y1),
                   control2: CGPoint(x: x0, y: y1 - r + r * k))
        p.addLine(to: CGPoint(x: x0, y: y0 + e))
        if e > 0 { p.addQuadCurve(to: CGPoint(x: x0 - e, y: y0), control: CGPoint(x: x0, y: y0)) }
        p.closeSubpath()
        return p
    }
}
