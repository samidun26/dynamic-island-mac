import AppKit
import NotchyCore
import SwiftUI

/// Root of the panel. The panel never resizes; everything happens inside this fixed canvas.
struct IslandRootView: View {
    let model: IslandModel

    var body: some View {
        IslandCanvas(model: model, state: model.state, geometry: model.geometry)
    }
}

/// Draws the island for an explicit state and geometry (the live view passes the model's,
/// snapshots pass their own).
struct IslandCanvas: View {
    let model: IslandModel
    let state: IslandState
    let geometry: IslandGeometry

    var body: some View {
        let canvas = model.metrics.canvasSize
        let open = state.isOpen
        ZStack(alignment: .top) {
            IslandShape(geometry)
                .fill(Color.black)
                .shadow(color: .black.opacity(open ? 0.55 : 0), radius: open ? 20 : 0, y: open ? 10 : 0)
            content
                .frame(width: max(1, geometry.size.width), height: max(1, geometry.size.height), alignment: .top)
                .clipShape(IslandShape(geometry, centred: true))
                .offset(x: geometry.offsetX)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    private var content: some View {
        ZStack(alignment: .top) {
            IslandStateContent(model: model, state: state)
                .id(contentID)
                .transition(model.reduceMotion ? .opacity : .islandContent)
        }
    }

    /// Changing identity is what triggers the content transition. Peek and expanded share one,
    /// so a peek that the user hovers into does not flash.
    private var contentID: String {
        switch state {
        case .idle: "idle"
        case .compact(let kind): "compact-\(kind.rawValue)"
        case .expanded, .peek: "expanded"
        }
    }
}

struct IslandStateContent: View {
    let model: IslandModel
    let state: IslandState

    var body: some View {
        switch state {
        case .idle:
            Color.clear.frame(width: 1, height: 1)
        case .compact(let kind):
            CompactContent(model: model, kind: kind, secondaries: model.secondaries)
        case .expanded(let page):
            ExpandedContent(model: model, page: page)
        case .peek(let kind):
            ExpandedContent(model: model, page: .activity(kind))
        }
    }
}

// MARK: - Compact

/// Live activity beside the notch; the middle stays clear for the camera. Normally split across
/// the two wings; on one side only, or as a lip under the notch, when menu bar items leave no
/// room (see `IslandModel.fit(for:secondaries:)`).
struct CompactContent: View {
    let model: IslandModel
    let kind: ActivityKind
    let secondaries: [ActivityKind]

    var body: some View {
        let notch = model.metrics.notchSize
        let fit = model.compactFit
        let inset = max(10, (notch.height * 0.3).rounded())
        let folded = fit.arrangement == .folded
        Group {
            switch fit.arrangement {
            case .split:
                HStack(spacing: 0) {
                    CompactLeading(model: model, kind: kind)
                        .padding(.leading, inset)
                        .frame(width: fit.left, alignment: .leading)
                    Color.clear.frame(width: notch.width)
                    trailing
                        .padding(.trailing, inset)
                        .frame(width: fit.right, alignment: .trailing)
                }
            case .right:
                HStack(spacing: 0) {
                    Color.clear.frame(width: notch.width)
                    together.padding(.horizontal, inset).frame(width: fit.right)
                }
            case .left:
                HStack(spacing: 0) {
                    together.padding(.horizontal, inset).frame(width: fit.left)
                    Color.clear.frame(width: notch.width)
                }
            case .folded:
                VStack(spacing: 0) {
                    Color.clear.frame(height: notch.height)
                    CompactLip(model: model, kind: kind).frame(height: NotchMetrics.lipHeight)
                }
            }
        }
        .frame(width: notch.width + fit.left + fit.right, height: notch.height + (folded ? NotchMetrics.lipHeight : 0))
        .foregroundStyle(.white)
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            ForEach(secondaries, id: \.self) { MinimalGlyph(model: model, kind: $0) }
            CompactTrailing(model: model, kind: kind)
        }
    }

    /// Leading and trailing content side by side, for a one-sided island.
    private var together: some View {
        HStack(spacing: 8) {
            CompactLeading(model: model, kind: kind)
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// A live activity with no room beside the notch: a thin tinted line in a lip under the notch,
/// showing its progress (track position, timer, level). Hovering opens the island as usual.
struct CompactLip: View {
    let model: IslandModel
    let kind: ActivityKind

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let v = value(at: ctx.date)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(v.color.opacity(0.3))
                    Capsule().fill(v.color).frame(width: max(2, geo.size.width * min(1, max(0, v.fraction))))
                }
                .frame(height: 2)
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 14)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(kind.rawValue))
    }

    private func value(at date: Date) -> (fraction: Double, color: Color) {
        switch kind {
        case .nowPlaying:
            // Streams and radio have no duration: a full line.
            (model.nowPlaying.info.map { ($0.duration ?? 0) > 0 ? $0.progress(at: date) : 1 } ?? 1, model.nowPlaying.tint)
        case .timer: (model.timer.progress(at: date), .orange)
        case .calendar: (1, model.calendar.phase.event?.color ?? .red)
        case .hud: (model.hud.current.map { $0.muted ? 0 : $0.level } ?? 0, .white)
        case .battery: (Double(model.battery.level ?? 100) / 100, .green)
        }
    }
}

// MARK: - Expanded

struct ExpandedContent: View {
    let model: IslandModel
    let page: Page

    var body: some View {
        let m = model.metrics
        let size = m.expandedSize()
        VStack(spacing: 0) {
            ExpandedHeader(model: model, page: page)
                .frame(height: m.notchSize.height)
            ZStack {
                pageView
                    .id(page)
                    .transition(model.reduceMotion ? .opacity : .page(model.pageDirection))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: page)
    }

    @ViewBuilder private var pageView: some View {
        switch page {
        case .activity(.nowPlaying): NowPlayingPage(model: model)
        case .activity(.timer): TimerPage(timer: model.timer)
        case .activity(.calendar): CalendarPage(calendar: model.calendar)
        case .activity(.battery), .activity(.hud), .home: HomePage(model: model)
        }
    }
}

/// The band beside the notch: what this page is on the left, page dots and battery on the right.
struct ExpandedHeader: View {
    let model: IslandModel
    let page: Page

    var body: some View {
        let m = model.metrics
        let side = (m.expandedSize().width - m.notchSize.width) / 2
        HStack(spacing: 0) {
            title
                .padding(.leading, 22)
                .frame(width: side, alignment: .leading)
            Color.clear.frame(width: m.notchSize.width)
            HStack(spacing: 10) {
                if let hud = model.hud.current, model.settings.hudEnabled {
                    // A volume/brightness key while open: the system HUD is suppressed, so show it here.
                    HStack(spacing: 6) {
                        HUDIcon(hud: hud).font(.system(size: 11))
                        LevelBar(level: hud.muted ? 0 : hud.level, dimmed: hud.muted).frame(width: 60)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if model.pages.count > 1 {
                    PageDots(model: model, current: page)
                }
                if let level = model.battery.level {
                    HStack(spacing: 4) {
                        Text("\(level)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                        BatteryGlyph(level: level, tint: batteryTint(level), width: 21)
                    }
                }
            }
            .padding(.trailing, 22)
            .frame(width: side, alignment: .trailing)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.hud.current == nil)
        }
        .lineLimit(1)
    }

    private func batteryTint(_ level: Int) -> Color {
        if model.battery.isCharging { return .green }
        return level <= 20 ? .red : .white.opacity(0.85)
    }

    @ViewBuilder private var title: some View {
        HStack(spacing: 6) {
            switch page {
            case .activity(.nowPlaying):
                if let icon = model.nowPlaying.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                } else {
                    Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                }
                Text(model.nowPlaying.appName.isEmpty ? "Now Playing" : model.nowPlaying.appName)
            case .activity(.timer):
                Image(systemName: "timer").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                Text("Timer")
            case .activity(.calendar):
                Image(systemName: "calendar").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                Text("Up Next")
            default:
                TimelineView(.everyMinute) { ctx in
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                }
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
    }
}

struct PageDots: View {
    let model: IslandModel
    let current: Page

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.pages, id: \.self) { p in
                Capsule()
                    .fill(.white.opacity(p == current ? 0.95 : 0.3))
                    .frame(width: p == current ? 12 : 5, height: 5)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { model.select(p) }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: current)
    }
}
