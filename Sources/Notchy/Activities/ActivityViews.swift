import AppKit
import NotchyCore
import SwiftUI

// MARK: - Compact slots

struct CompactLeading: View {
    let model: IslandModel
    let kind: ActivityKind

    var body: some View {
        let h = model.metrics.notchSize.height
        switch kind {
        case .nowPlaying:
            ArtworkView(image: model.nowPlaying.artwork, fallback: model.nowPlaying.appIcon, side: max(16, h - 12))
        case .timer:
            Image(systemName: model.timer.isDone ? "bell.fill" : "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: model.timer.isDone)
        case .calendar:
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.calendar.phase.event?.color ?? .red)
        case .hud:
            HUDIcon(hud: model.hud.current)
        case .battery:
            BatteryBannerLeading(battery: model.battery)
        }
    }
}

struct CompactTrailing: View {
    let model: IslandModel
    let kind: ActivityKind

    var body: some View {
        let h = model.metrics.notchSize.height
        switch kind {
        case .nowPlaying:
            AudioBars(playing: model.nowPlaying.info?.isPlaying ?? false, tint: model.nowPlaying.tint, height: (h * 0.42).rounded())
        case .timer:
            TimerText(timer: model.timer, size: 13)
        case .calendar:
            if let e = model.calendar.phase.event {
                RelativeTime(date: e.start)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(e.color)
            }
        case .hud:
            if let c = model.hud.current {
                LevelBar(level: c.muted ? 0 : c.level, dimmed: c.muted)
                    .frame(width: 54)
            }
        case .battery:
            if let level = model.battery.level {
                HStack(spacing: 5) {
                    Text("\(level)%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    BatteryGlyph(level: level, tint: model.battery.banner?.kind == .low ? .red : .green, width: 22)
                }
                .foregroundStyle(model.battery.banner?.kind == .low ? .red : .green)
            }
        }
    }
}

/// Tiny glyph for an activity that is running but not in front.
struct MinimalGlyph: View {
    let model: IslandModel
    let kind: ActivityKind

    var body: some View {
        Group {
            switch kind {
            case .nowPlaying:
                ArtworkView(image: model.nowPlaying.artwork, fallback: model.nowPlaying.appIcon, side: 15)
            case .timer:
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Ring(progress: model.timer.progress(at: ctx.date), tint: .orange, lineWidth: 2.2)
                }
                .frame(width: 14, height: 14)
            case .calendar:
                Circle().fill(model.calendar.phase.event?.color ?? .red).frame(width: 7, height: 7)
            case .hud, .battery:
                EmptyView()
            }
        }
        .frame(width: IslandModel.minimalSlot - 6)
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Shared bits

struct TimerText: View {
    let timer: TimerModel
    var size: CGFloat

    var body: some View {
        Group {
            if timer.isDone {
                Text("Done")
            } else if let end = timer.endDate {
                Text(timerInterval: Date()...max(Date(), end), countsDown: true, showsHours: true)
            } else {
                Text(formatDuration(timer.remaining())).opacity(0.6)
            }
        }
        .countdownFont(size)
        .foregroundStyle(.orange)
        .lineLimit(1)
        .fixedSize()
    }
}

/// "in 4m", "in 1h 5m", "now". Ticks once a minute on the event's own second (not the wall
/// clock's), so "in 4m" changes to "in 3m" exactly when 3 minutes remain.
struct RelativeTime: View {
    let date: Date

    var body: some View {
        let ahead = date.timeIntervalSinceNow
        let anchor = date.addingTimeInterval(-60 * (ahead / 60).rounded(.up))
        TimelineView(.periodic(from: anchor, by: 60)) { ctx in
            Text(Self.text(date.timeIntervalSince(ctx.date)))
        }
    }

    static func text(_ dt: TimeInterval) -> String {
        if dt <= 30 { return dt > -300 ? "now" : "started" }
        let m = Int((dt / 60).rounded(.up))
        return m < 60 ? "in \(m)m" : "in \(m / 60)h \(m % 60)m"
    }
}

struct LevelBar: View {
    var level: Double
    var dimmed = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(dimmed ? 0.35 : 1)).frame(width: max(5, g.size.width * level))
            }
        }
        .frame(height: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
    }
}

struct HUDIcon: View {
    let hud: HUDModel.Current?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 20)
    }

    private var symbol: String {
        guard let hud else { return "speaker.wave.2.fill" }
        switch hud.kind {
        case .brightness:
            return hud.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if hud.muted || hud.level <= 0.001 { return "speaker.slash.fill" }
            return hud.level < 0.34 ? "speaker.wave.1.fill" : hud.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
}

struct BatteryBannerLeading: View {
    let battery: BatteryModel

    var body: some View {
        let kind = battery.banner?.kind ?? .charging
        HStack(spacing: 4) {
            Image(systemName: kind == .low ? "battery.25percent" : "bolt.fill")
                .font(.system(size: 11, weight: .bold))
                .symbolEffect(.bounce, value: battery.banner?.at)
            Text(kind == .low ? "Low Battery" : kind == .charging ? "Charging" : "Connected")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(kind == .low ? .red : .green)
    }
}

// MARK: - Expanded pages

struct NowPlayingPage: View {
    let model: IslandModel

    var body: some View {
        let np = model.nowPlaying
        if let info = np.info {
            HStack(alignment: .center, spacing: 16) {
                ArtworkView(image: np.artwork, fallback: np.appIcon, side: 80, glow: np.tint)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title).font(.system(size: 14.5, weight: .semibold))
                            Text(info.artist.isEmpty ? info.album : info.artist)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .lineLimit(1)
                        Spacer(minLength: 4)
                        AudioBars(playing: info.isPlaying, tint: np.tint, height: 16)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 4)
                    Scrubber(info: info, tint: np.tint) { np.seek(toFraction: $0) }
                    Spacer(minLength: 2)
                    HStack(spacing: 2) {
                        IconButton(symbol: "backward.fill", label: "Previous track", size: 15) { np.send(.previous) }
                        IconButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", label: info.isPlaying ? "Pause" : "Play", size: 21, box: 34) { np.send(.togglePlayPause) }
                        IconButton(symbol: "forward.fill", label: "Next track", size: 15) { np.send(.next) }
                        Spacer(minLength: 12)
                        VolumeControl(hud: model.hud)
                            .frame(width: 112)
                    }
                    .padding(.leading, -6)
                }
            }
        } else {
            HomePage(model: model)
        }
    }
}

struct VolumeControl: View {
    let hud: HUDModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hud.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16)
            LevelSlider(value: hud.muted ? 0 : hud.volume, label: "Volume", tint: .white.opacity(0.9)) { hud.setVolume($0) }
        }
    }
}

struct TimerPage: View {
    let timer: TimerModel

    var body: some View {
        HStack(spacing: 18) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                ZStack {
                    Ring(progress: timer.progress(at: ctx.date), tint: .orange, lineWidth: 6)
                        .animation(.linear(duration: 0.5), value: timer.progress(at: ctx.date))
                    Image(systemName: timer.isDone ? "bell.fill" : "timer")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.orange)
                        .symbolEffect(.bounce, value: timer.finishedAt)
                }
            }
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 0) {
                Text(timer.isDone ? "Time's up" : timer.isPaused ? "Paused" : "Timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                TimerText(timer: timer, size: 36)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if timer.isDone {
                    PillButton(title: "Dismiss", tint: .orange) { timer.cancel() }
                } else {
                    PillButton(title: "+1 min", tint: .orange) { timer.add(60) }
                    IconButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", label: timer.isPaused ? "Resume timer" : "Pause timer", size: 14, box: 32, tint: .orange) {
                        if timer.isPaused { timer.resume() } else { timer.pause() }
                    }
                    .background(Circle().fill(.orange.opacity(0.16)))
                    IconButton(symbol: "xmark", label: "Cancel timer", size: 12, box: 32, tint: .white.opacity(0.8)) { timer.cancel() }
                        .background(Circle().fill(.white.opacity(0.1)))
                }
            }
        }
    }
}

struct CalendarPage: View {
    let calendar: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(calendar.upcoming.prefix(3)) { e in
                EventRow(event: e)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct EventRow: View {
    let event: CalendarModel.Event
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(event.color).frame(width: 3.5, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(timeRange + (event.location.map { $0.isEmpty ? "" : "  ·  \($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            RelativeTime(date: event.start)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(event.color)
            if let url = event.joinURL {
                PillButton(title: "Join", symbol: "video.fill", tint: .green) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var timeRange: String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(event.start.formatted(f)) – \(event.end.formatted(f))"
    }
}

/// Shown when nothing else has a page: clock, next event, quick timers.
struct HomePage: View {
    let model: IslandModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.everyMinute) { ctx in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ctx.date, format: .dateTime.hour().minute())
                            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer(minLength: 6)
                if model.settings.timerEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "timer").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                        ForEach([1, 5, 10, 25], id: \.self) { m in
                            PillButton(title: "\(m)m", tint: .orange) { model.timer.start(TimeInterval(m * 60)) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            NextUpCard(model: model)
                .frame(width: 190)
        }
    }
}

struct NextUpCard: View {
    let model: IslandModel

    var body: some View {
        let cal = model.calendar
        VStack(alignment: .leading, spacing: 6) {
            Text("UP NEXT")
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(.white.opacity(0.4))
            if !model.settings.calendarEnabled {
                Text("Calendar is off").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            } else if cal.access == .denied {
                Text("No calendar access").font(.system(size: 12, weight: .semibold))
                PillButton(title: "Open Settings", tint: .white) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            } else if cal.access == .notDetermined {
                PillButton(title: "Allow Calendar", symbol: "calendar", tint: .red) { cal.requestAccess() }
            } else if let e = cal.upcoming.first {
                HStack(spacing: 8) {
                    Capsule().fill(e.color).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(e.start, format: .dateTime.hour().minute())
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                HStack(spacing: 6) {
                    RelativeTime(date: e.start)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(e.color)
                    if let url = e.joinURL {
                        PillButton(title: "Join", symbol: "video.fill", tint: .green) { NSWorkspace.shared.open(url) }
                    }
                }
            } else {
                Text("Nothing else today").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07)))
    }
}
