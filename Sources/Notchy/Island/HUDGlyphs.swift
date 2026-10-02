import SwiftUI

// Volume and brightness glyphs that show the level itself, not just the kind: the speaker's sound
// waves grow one after another as the volume rises, and the sun gains its rays one by one up to
// a full ring at maximum. Every part is an animatable shape, so a change glides instead of
// swapping between fixed symbols.

/// Speaker with sound waves for the volume: none at zero, then each wave grows from its middle
/// outward in turn; at full volume all three are whole. Muting draws a slash across it.
struct SpeakerGlyph: View {
    var level: Double
    var muted: Bool
    var size: CGFloat = 16
    var tint: Color = .white

    var body: some View {
        let shown = muted ? 0 : min(1, max(0, level))
        let line = StrokeStyle(lineWidth: max(1.2, size * 0.1), lineCap: .round, lineJoin: .round)
        ZStack {
            SpeakerBody().fill(tint)
            SoundWaves(level: shown).stroke(tint, style: line)
            MuteSlash(progress: muted ? 1 : 0).stroke(tint, style: line)
        }
        .frame(width: size * 1.3, height: size)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: shown)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: muted)
        .accessibilityHidden(true)
    }
}

private struct SpeakerBody: Shape {
    func path(in r: CGRect) -> Path {
        let h = r.height, x = r.minX, y = r.minY
        var p = Path()
        p.addRoundedRect(in: CGRect(x: x, y: y + h * 0.34, width: h * 0.26, height: h * 0.32), cornerSize: CGSize(width: h * 0.05, height: h * 0.05))
        p.move(to: CGPoint(x: x + h * 0.24, y: y + h * 0.34))
        p.addLine(to: CGPoint(x: x + h * 0.56, y: y + h * 0.08))
        p.addQuadCurve(to: CGPoint(x: x + h * 0.56, y: y + h * 0.92), control: CGPoint(x: x + h * 0.64, y: y + h * 0.5))
        p.addLine(to: CGPoint(x: x + h * 0.24, y: y + h * 0.66))
        p.closeSubpath()
        return p
    }
}

private struct SoundWaves: Shape {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in r: CGRect) -> Path {
        let h = r.height
        let center = CGPoint(x: r.minX + h * 0.5, y: r.midY)
        var p = Path()
        for i in 0..<3 {
            // Each wave takes a third of the range; within it, it grows from its middle.
            let v = min(1, max(0, level * 3 - Double(i)))
            guard v > 0.02 else { continue }
            let radius = h * (0.3 + 0.2 * CGFloat(i))
            let half = 42 * v
            p.addArc(center: center, radius: radius, startAngle: .degrees(-half), endAngle: .degrees(half), clockwise: false)
        }
        return p
    }
}

private struct MuteSlash: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        guard progress > 0.01 else { return Path() }
        let a = CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.06)
        let b = CGPoint(x: r.minX + r.width * 0.86, y: r.maxY - r.height * 0.06)
        var p = Path()
        p.move(to: a)
        p.addLine(to: CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress))
        return p
    }
}

/// Sun for the brightness: its core swells and its eight rays light up one by one, clockwise from
/// the top; at full brightness every ray is drawn whole.
struct SunGlyph: View {
    var level: Double
    var size: CGFloat = 16
    var tint: Color = .white

    var body: some View {
        let v = min(1, max(0, level))
        ZStack {
            SunRays(level: v).stroke(tint, style: StrokeStyle(lineWidth: max(1.2, size * 0.1), lineCap: .round))
            SunCore(level: v).fill(tint)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: v)
        .accessibilityHidden(true)
    }
}

private struct SunCore: Shape {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height)
        let radius = s * (0.16 + 0.08 * level)
        return Path(ellipseIn: CGRect(x: r.midX - radius, y: r.midY - radius, width: radius * 2, height: radius * 2))
    }
}

private struct SunRays: Shape {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height)
        let inner = s * 0.33, outer = s * 0.47
        var p = Path()
        for k in 0..<8 {
            let v = min(1, max(0, level * 8 - Double(k)))
            guard v > 0.02 else { continue }
            let angle = Angle.degrees(-90 + 45 * Double(k)).radians
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let end = inner + (outer - inner) * v
            p.move(to: CGPoint(x: r.midX + dir.x * inner, y: r.midY + dir.y * inner))
            p.addLine(to: CGPoint(x: r.midX + dir.x * end, y: r.midY + dir.y * end))
        }
        return p
    }
}

/// The glyph for whatever the keys just changed, with a small bounce on every press.
struct HUDGlyph: View {
    let hud: HUDModel.Current?
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            if hud?.kind == .brightness {
                SunGlyph(level: hud?.level ?? 0, size: size)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                SpeakerGlyph(level: hud?.level ?? 0.5, muted: hud?.muted ?? false, size: size)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: size * 1.3, height: size)
        .keyframeAnimator(initialValue: 1.0, trigger: hud?.presses ?? 0) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(1.16, duration: 0.08, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hud?.kind)
    }
}
