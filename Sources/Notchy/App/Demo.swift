import AppKit
import NotchyCore
import SwiftUI

/// Fake states for verifying the UI without a mouse, music or calendar
/// (`--demo <scenario>` for a live panel, `--snapshot <dir>` for PNGs).
enum DemoScenario: String, CaseIterable {
    case idle, compact, expanded, peek, multi, timer, timerExpanded, hud, battery, calendar, calendarExpanded, home
    case pomodoro, pomodoroExpanded, shelf, clipboard
}

@MainActor
enum Demo {
    static func artwork() -> NSImage {
        let art = ZStack {
            LinearGradient(colors: [Color(red: 0.99, green: 0.38, blue: 0.45), Color(red: 0.38, green: 0.16, blue: 0.72)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1, green: 0.8, blue: 0.4)).frame(width: 130).offset(x: 55, y: -50)
            Rectangle().fill(Color.black.opacity(0.28)).frame(height: 90).offset(y: 105)
            Text("M83").font(.system(size: 54, weight: .black)).foregroundStyle(.white.opacity(0.9)).offset(x: -60, y: 70)
        }
        .frame(width: 300, height: 300)
        let r = ImageRenderer(content: art)
        r.scale = 1
        return r.nsImage ?? NSImage(size: NSSize(width: 300, height: 300))
    }

    static func track(playing: Bool = true) -> NowPlayingInfo {
        NowPlayingInfo(bundleID: "com.spotify.client", title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                       duration: 243, elapsed: 61, timestamp: Date(), playbackRate: 1, isPlaying: playing)
    }

    static func events(_ now: Date = Date()) -> [CalendarModel.Event] {
        [
            .init(id: "1", title: "Design review", start: now + 4 * 60, end: now + 34 * 60, color: .orange,
                  location: "Studio 2", joinURL: URL(string: "https://zoom.us/j/123")),
            .init(id: "2", title: "Lunch with Sam", start: now + 2 * 3600, end: now + 3 * 3600, color: .green,
                  location: "Café Lumen", joinURL: nil),
            .init(id: "3", title: "1:1 with Alex", start: now + 4 * 3600, end: now + 4.5 * 3600, color: .blue,
                  location: nil, joinURL: URL(string: "https://meet.google.com/abc-defg-hij")),
        ]
    }

    /// Files on the shelf: real paths that exist on every Mac, so Finder icons render.
    static let shelfFiles = ["/Applications/Safari.app", "/System/Library/CoreServices/Finder.app",
                             "/Library/Desktop Pictures", "/etc/hosts", "/usr/share/dict/words"].map { URL(fileURLWithPath: $0) }

    static let clips = ["https://github.com/samidun26/dynamic-island-mac", "#FF6B54", "Meeting moved to 3:30, same room",
                        "hello@example.com", "let island = IslandModel(settings: settings, metrics: metrics)"]

    static func apply(_ scenario: DemoScenario, to model: IslandModel) {
        let art = artwork()
        let tint = Color(red: 0.99, green: 0.5, blue: 0.6)
        func music() { model.nowPlaying.showDemo(track(), artwork: art, tint: tint) }
        func timer() { model.timer.showDemo(remaining: 272, total: 300) }
        func calendar(_ phase: Bool) {
            let ev = events()
            model.calendar.showDemo(ev, phase: phase ? .imminent(ev[0]) : .none)
        }
        model.battery.showDemo(level: 82, charging: false, banner: nil)

        switch scenario {
        case .idle: break
        case .compact: music()
        case .expanded: music(); model.click()
        case .peek: music(); model.peek(.nowPlaying, seconds: 3600)
        case .multi: music(); timer()
        case .timer: timer()
        case .timerExpanded: timer(); model.click()
        case .hud: music(); model.hud.show(.volume, level: 0.62, muted: false)
        case .battery: model.battery.showDemo(level: 76, charging: true, banner: .charging)
        case .calendar: calendar(true)
        case .calendarExpanded: calendar(true); model.click()
        case .home: calendar(false); model.click()
        case .pomodoro: music(); model.timer.showDemo(remaining: 1104, total: 1500, pomodoro: .focus(round: 2))
        case .pomodoroExpanded: model.timer.showDemo(remaining: 1104, total: 1500, pomodoro: .focus(round: 2)); model.click()
        case .shelf:
            model.shelf.showDemo(shelfFiles)
            model.clipboard.showDemo(clips, pinned: ["#FF6B54"])
            model.openShelf(.files)
        case .clipboard:
            model.shelf.showDemo(shelfFiles)
            model.clipboard.showDemo(clips, pinned: ["#FF6B54"])
            model.openShelf(.clipboard)
        }
        model.refresh()
    }
}

// MARK: - Snapshots

@MainActor
enum Snapshots {
    /// 14" MacBook Pro geometry and a 1080p external display.
    static let notched = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                      auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, menuBarHeight: 32)
    static let plain = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                                    auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 24)

    /// Free menu bar beside the notch in the snapshots: the mock menus end, and the mock icons
    /// start, this far from the notch.
    nonisolated static let roomy = MenuBarClearance(left: 90, right: 90)

    static func model(_ metrics: NotchMetrics, _ scenario: DemoScenario, clearance: MenuBarClearance = roomy,
                      style: IslandStyle = .classic, phosphor: Phosphor = .color) -> IslandModel {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.phosphor = phosphor
        let m = IslandModel(settings: settings, metrics: metrics)
        m.menuBar.showDemo(clearance)
        Demo.apply(scenario, to: m)
        return m
    }

    /// Menu bars crowded in different ways: the compact island never covers a menu or an icon.
    static let crowded: [(String, DemoScenario, MenuBarClearance)] = [
        ("room on both sides: wings either side", .compact, roomy),
        ("menus 44 pt from the notch: narrower wings", .compact, MenuBarClearance(left: 44, right: 120)),
        ("app menus reach the notch: everything moves right", .compact, MenuBarClearance(left: 8, right: 120)),
        ("menu bar icons reach the notch: everything moves left", .compact, MenuBarClearance(left: 120, right: 8)),
        ("no room either side: a progress line under the notch", .compact, MenuBarClearance(left: 8, right: 10)),
        ("timer with music, app menus reach the notch", .multi, MenuBarClearance(left: 8, right: 160)),
        ("timer, no room either side", .timer, MenuBarClearance(left: 8, right: 10)),
    ]

    static func render(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, metrics) in [("notch", notched), ("nonotch", plain)] {
            var rows: [(String, AnyView)] = []
            for s in DemoScenario.allCases {
                let m = model(metrics, s)
                let scene = AnyView(SnapshotScene(metrics: metrics, clearance: roomy) { IslandCanvas(model: m, state: m.state, geometry: m.geometry) })
                write(scene, "\(dir)/\(name)-\(s.rawValue).png")
                rows.append((s.rawValue, scene))
            }
            // Hover nudge in click-to-open mode.
            let bumped = model(metrics, .compact)
            bumped.settings.openOnHover = false
            bumped.setHovering(true)
            bumped.refresh()
            rows.append(("compact + hover (click mode)", AnyView(SnapshotScene(metrics: metrics, clearance: roomy) {
                IslandCanvas(model: bumped, state: bumped.state, geometry: bumped.geometry)
            })))
            write(Sheet(rows: rows), "\(dir)/sheet-\(name).png")
        }
        var menuRows: [(String, AnyView)] = []
        for (i, (title, scenario, clearance)) in crowded.enumerated() {
            let m = model(notched, scenario, clearance: clearance)
            let scene = AnyView(SnapshotScene(metrics: notched, clearance: clearance) { IslandCanvas(model: m, state: m.state, geometry: m.geometry) })
            write(scene, "\(dir)/menubar-\(i + 1).png")
            menuRows.append((title, scene))
        }
        write(Sheet(rows: menuRows), "\(dir)/sheet-menubar.png")

        // Retro style: every state in full colour, then the one-colour screens.
        var retroRows: [(String, AnyView)] = []
        let retroCases: [(String, DemoScenario, MenuBarClearance, Phosphor)] = [
            ("retro · compact", .compact, roomy, .color),
            ("retro · now playing", .expanded, roomy, .color),
            ("retro · timer with music", .multi, roomy, .color),
            ("retro · timer", .timerExpanded, roomy, .color),
            ("retro · up next", .calendarExpanded, roomy, .color),
            ("retro · home", .home, roomy, .color),
            ("retro · pomodoro", .pomodoroExpanded, roomy, .color),
            ("retro · shelf", .shelf, roomy, .color),
            ("retro · clipboard", .clipboard, roomy, .color),
            ("retro · volume", .hud, roomy, .color),
            ("retro · no room beside the notch", .compact, MenuBarClearance(left: 8, right: 10), .color),
            ("retro · green screen", .expanded, roomy, .green),
            ("retro · amber screen", .expanded, roomy, .amber),
            ("retro · amber, compact", .compact, roomy, .amber),
        ]
        for (title, scenario, clearance, phosphor) in retroCases {
            let m = model(notched, scenario, clearance: clearance, style: .retro, phosphor: phosphor)
            let scene = AnyView(SnapshotScene(metrics: notched, clearance: clearance) { IslandCanvas(model: m, state: m.state, geometry: m.geometry) })
            retroRows.append((title, scene))
            if title == "retro · compact" { write(scene, "\(dir)/retro-compact.png") }
            if title == "retro · now playing" { write(scene, "\(dir)/retro-expanded.png") }
            if title == "retro · green screen" { write(scene, "\(dir)/retro-green.png") }
        }
        write(Sheet(rows: retroRows), "\(dir)/sheet-retro.png")

        // Volume and brightness through their range: the glyph shows the level (waves, rays).
        var hudRows: [(String, AnyView)] = []
        let hudCases: [(String, HUDModel.Kind, Double, Bool)] = [
            ("volume 0%", .volume, 0, false), ("volume 20%", .volume, 0.2, false), ("volume 50%", .volume, 0.5, false),
            ("volume 80%", .volume, 0.8, false), ("volume 100%", .volume, 1, false), ("volume muted", .volume, 0.6, true),
            ("brightness 5%", .brightness, 0.05, false), ("brightness 30%", .brightness, 0.3, false),
            ("brightness 60%", .brightness, 0.6, false), ("brightness 100%", .brightness, 1, false),
        ]
        for (title, kind, level, muted) in hudCases {
            let m = model(notched, .idle)
            m.hud.show(kind, level: level, muted: muted)
            m.refresh()
            let scene = AnyView(SnapshotScene(metrics: notched) { IslandCanvas(model: m, state: m.state, geometry: m.geometry) })
            hudRows.append((title, scene))
            if title == "volume 50%" { write(scene, "\(dir)/hud-volume.png") }
            if title == "brightness 100%" { write(scene, "\(dir)/hud-brightness.png") }
        }
        write(Sheet(rows: hudRows), "\(dir)/sheet-hud.png")
        filmstrip(opening: true, to: "\(dir)/filmstrip-open.png")
        filmstrip(opening: false, to: "\(dir)/filmstrip-close.png")
        write(AppIcon.IconView().frame(width: 256, height: 256), "\(dir)/app-icon.png")
    }

    /// Frames of compact → expanded (or back) computed from the same springs the app uses.
    /// SwiftUI's own interpolation is not captured; this checks shape, clip and content timing.
    static func filmstrip(opening: Bool, to path: String) {
        let m = model(notched, .compact)
        let compact = m.state, compactG = m.geometry
        m.click()
        m.refresh()
        let expanded = m.state, expandedG = m.geometry
        let s = m.settings
        let spring = opening ? SpringCurve(response: s.openResponse, dampingFraction: s.openDamping)
                             : SpringCurve(response: s.closeResponse, dampingFraction: s.closeDamping)
        let times: [Double] = [0, 0.04, 0.08, 0.12, 0.17, 0.23, 0.3, 0.4, 0.55, 0.8]
        let rows = times.map { t in
            ("\(Int(t * 1000)) ms", AnyView(SnapshotScene(metrics: notched) {
                FilmFrame(model: m,
                          from: opening ? compact : expanded, to: opening ? expanded : compact,
                          fromG: opening ? compactG : expandedG, toG: opening ? expandedG : compactG,
                          t: t, spring: spring)
            }))
        }
        write(Sheet(rows: rows), path)
    }

    static func write<V: View>(_ view: V, _ path: String) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.staticRender, true))
        r.scale = 2
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("failed to render \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// Wallpaper and menu bar behind the canvas, so the fused edges are visible in snapshots. The mock
/// menus end, and the mock icons start, `clearance` points from the notch.
private struct SnapshotScene<Content: View>: View {
    let metrics: NotchMetrics
    var clearance = Snapshots.roomy
    @ViewBuilder let content: Content

    var body: some View {
        let c = metrics.canvasSize
        let bar = metrics.hasNotch ? metrics.notchSize.height : metrics.notchSize.height - 8
        let notchLeft = (c.width - metrics.notchSize.width) / 2
        let notchRight = notchLeft + metrics.notchSize.width
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.17, blue: 0.42), Color(red: 0.52, green: 0.3, blue: 0.62),
                                    Color(red: 0.96, green: 0.63, blue: 0.46)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.white.opacity(0.16)).frame(height: bar)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 14) {
                    Text("File"); Text("Edit"); Text("View"); Text("Window"); Text("Help")
                }
                .fixedSize()
                .frame(width: max(0, notchLeft - (clearance.left ?? 0)), height: bar, alignment: .trailing)
                HStack(spacing: 14) {
                    Image(systemName: "wifi"); Image(systemName: "battery.75percent"); Text("Wed 10:42")
                }
                .fixedSize()
                .frame(height: bar)
                .offset(x: notchRight + clearance.right)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: c.width, height: bar, alignment: .topLeading)
            .clipped()
            if metrics.hasNotch {
                // The physical notch: the idle island must cover it exactly.
                IslandShape(metrics.idle()).fill(Color.black)
            }
            content
        }
        .frame(width: c.width, height: c.height)
        .clipped()
    }
}

private struct Sheet: View {
    let rows: [(String, AnyView)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(rows[i].0).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    rows[i].1
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.1))
    }
}

/// One frame of a transition, rebuilt from the spring curves (shape) and the content
/// transition timings in `AnyTransition.islandContent`.
private struct FilmFrame: View {
    let model: IslandModel
    let from: IslandState
    let to: IslandState
    let fromG: IslandGeometry
    let toG: IslandGeometry
    let t: Double
    let spring: SpringCurve

    var body: some View {
        let g = IslandGeometry.lerp(fromG, toG, CGFloat(spring.value(at: t)))
        let out = min(1, t / 0.13)
        let inn = 1 - min(1, max(0, SpringCurve(response: 0.42, dampingFraction: 0.92).value(at: t - 0.06)))
        let open = to.isOpen
        let canvas = model.metrics.canvasSize
        ZStack(alignment: .top) {
            IslandShape(g).fill(Color.black)
                .shadow(color: .black.opacity(0.55 * (open ? min(1, t / 0.2) : max(0, 1 - t / 0.2))), radius: 20, y: 10)
            ZStack(alignment: .top) {
                IslandStateContent(model: model, state: from).modifier(BlurFade(amount: out))
                IslandStateContent(model: model, state: to).modifier(BlurFade(amount: inn))
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .clipShape(IslandShape(g))
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
    }
}

// MARK: - App icon

@MainActor
enum AppIcon {
    /// The icon artwork (Resources/AppIconArt.jpg, a 1200 px square on white), cropped to the cat.
    /// From the app bundle, or from a file when the bare binary renders the iconset during the build.
    static func art(path: String? = nil) -> NSImage? {
        let url = path.map { URL(fileURLWithPath: $0) } ?? Bundle.main.url(forResource: "AppIconArt", withExtension: "jpg")
        guard let url, let source = NSImage(contentsOf: url),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // The head with its ears and whiskers sits in this square of the 1200 px original.
        let k = CGFloat(cg.width) / 1200
        guard let cropped = cg.cropping(to: CGRect(x: 240 * k, y: 220 * k, width: 720 * k, height: 720 * k)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    struct IconView: View {
        var art: NSImage? = AppIcon.art()

        var body: some View {
            GeometryReader { geo in
                let s = geo.size.width
                let w = s * 0.805 // macOS icon grid: 824 of 1024
                let shape = RoundedRectangle(cornerRadius: w * 0.225, style: .continuous)
                ZStack {
                    // Warm paper white, a touch brighter where the face is.
                    RadialGradient(colors: [Color(red: 1, green: 0.995, blue: 0.985), Color(red: 0.93, green: 0.905, blue: 0.87)],
                                   center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: w * 0.72)
                    if let art {
                        // Multiply drops the artwork's white background onto the paper.
                        Image(nsImage: art)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: w * 0.94, height: w * 0.94)
                            .offset(y: w * 0.03)
                            .blendMode(.multiply)
                    }
                }
                .compositingGroup()
                .frame(width: w, height: w)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: max(0.5, s * 0.002)))
                .shadow(color: .black.opacity(0.28), radius: s * 0.02, y: s * 0.012)
                .frame(width: s, height: s)
            }
        }
    }

    /// Writes the PNGs `iconutil -c icns` expects.
    static func renderIconset(to dir: String, artPath: String?) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let art = AppIcon.art(path: artPath)
        if art == nil { print("icon art not found at \(artPath ?? "the app bundle")") }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(base * scale)
                let r = ImageRenderer(content: IconView(art: art).frame(width: px, height: px))
                r.scale = 1
                guard let cg = r.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
