import AppKit
import NotchyCore
import SwiftUI

// MARK: - Transitions

/// Content enters blurred and slightly small, settling a beat after the shape starts moving;
/// it leaves quickly so it is gone before the shape shrinks over it.
struct BlurFade: ViewModifier {
    var amount: Double // 0 = settled, 1 = gone
    func body(content: Content) -> some View {
        content
            .blur(radius: 10 * amount)
            .scaleEffect(1 - 0.08 * amount, anchor: .top)
            .opacity(1 - amount)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
                .animation(.spring(response: 0.42, dampingFraction: 0.92).delay(0.06)),
            removal: .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
                .animation(.easeOut(duration: 0.13))
        )
    }

    /// Horizontal carousel between expanded pages.
    static func page(_ direction: Int) -> AnyTransition {
        let d: CGFloat = direction >= 0 ? 1 : -1
        return .asymmetric(
            insertion: .offset(x: 70 * d).combined(with: .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))),
            removal: .offset(x: -70 * d).combined(with: .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0)))
        )
    }
}

// MARK: - Buttons

struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    /// Spoken by VoiceOver.
    var label: String = ""
    var size: CGFloat = 15
    var box: CGFloat = 30
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint)
                .frame(width: box, height: box)
                .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel(label.isEmpty ? symbol : label)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle())
    }
}

// MARK: - Media

struct ArtworkView: View {
    let image: NSImage?
    var fallback: NSImage?
    let side: CGFloat
    var glow: Color?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                    .id(ObjectIdentifier(image))
            } else {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
                if let fallback {
                    Image(nsImage: fallback).resizable().aspectRatio(contentMode: .fit).padding(side * 0.18)
                } else {
                    Image(systemName: "music.note").font(.system(size: side * 0.42, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: (glow ?? .clear).opacity(0.35), radius: side * 0.16, y: side * 0.04)
        .animation(.easeInOut(duration: 0.3), value: image.map(ObjectIdentifier.init))
    }
}

/// The iPhone-style equaliser. Driven by time, not audio (reading real levels would need
/// screen/audio capture permission). Only animates while visible and playing.
struct AudioBars: View {
    var playing: Bool
    var tint: Color
    var height: CGFloat = 14
    var barWidth: CGFloat = 3
    var count = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth * 0.8) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(width: barWidth, height: playing ? max(barWidth, level(i, t) * height) : barWidth)
                }
            }
            .frame(height: height)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: playing)
    }

    private func level(_ i: Int, _ t: Double) -> CGFloat {
        let f = [2.3, 3.1, 2.7, 3.7, 2.9][i % 5]
        let p = [0.0, 1.3, 2.5, 0.7, 1.9][i % 5]
        let v = 0.55 + 0.28 * sin(t * f * 2.1 + p) + 0.17 * sin(t * f * 4.3 + p * 2)
        return CGFloat(min(1, max(0.2, v)))
    }
}

/// Progress bar you can grab and drag to seek. Interpolates the playhead locally.
struct Scrubber: View {
    let info: NowPlayingInfo
    let tint: Color
    let onSeek: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let p = drag ?? info.progress(at: ctx.date)
            let duration = info.duration ?? 0
            let elapsed = drag.map { $0 * duration } ?? info.position(at: ctx.date) ?? 0
            HStack(spacing: 8) {
                Text(formatDuration(elapsed)).frame(width: 34, alignment: .trailing)
                GeometryReader { g in
                    let barHeight: CGFloat = drag == nil ? 5 : 8
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(tint).frame(width: max(barHeight, g.size.width * p))
                    }
                    .frame(height: barHeight)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in drag = min(1, max(0, v.location.x / max(1, g.size.width))) }
                        .onEnded { _ in
                            if let d = drag { onSeek(d) }
                            drag = nil
                        })
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: drag == nil)
                    .animation(.linear(duration: 0.5), value: drag == nil ? p : nil)
                }
                .frame(height: 14)
                Text("-" + formatDuration(max(0, duration - elapsed))).frame(width: 38, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .opacity(duration > 0 ? 1 : 0.4)
        }
    }
}

/// A draggable level bar (volume).
struct LevelSlider: View {
    let value: Double
    var tint: Color = .white
    let onChange: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        GeometryReader { g in
            let v = drag ?? value
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(tint).frame(width: max(4, g.size.width * v))
            }
            .frame(height: drag == nil ? 4 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { e in
                    let nv = min(1, max(0, e.location.x / max(1, g.size.width)))
                    drag = nv
                    onChange(nv)
                }
                .onEnded { _ in drag = nil })
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: drag == nil)
        }
        .frame(height: 14)
    }
}

// MARK: - Glyphs

struct Ring: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

struct BatteryGlyph: View {
    var level: Int
    var tint: Color
    var width: CGFloat = 24

    var body: some View {
        let h = width * 0.48
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: h * 0.18, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, (width - 4) * CGFloat(min(100, max(0, level))) / 100))
                    .padding(2)
            }
            .frame(width: width, height: h)
            Capsule().fill(.white.opacity(0.4)).frame(width: 1.5, height: h * 0.4)
        }
    }
}

extension View {
    /// Monospaced digits in the rounded system face, for countdowns.
    func countdownFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight, design: .rounded).monospacedDigit())
    }
}
