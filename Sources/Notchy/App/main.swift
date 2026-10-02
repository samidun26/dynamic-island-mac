import AppKit

// Entry point. Extra modes for verification without a mouse:
//   --demo <scenario> [--print-window]   fake activities, live panel (see DemoScenario)
//   --snapshot <dir>                      render every state to PNG and exit
//   --render-icon <dir>                   write AppIcon.iconset PNGs and exit
MainActor.assumeIsolated {
    let args = CommandLine.arguments
    func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    let app = NSApplication.shared
    RetroFonts.register()
    if let dir = value(after: "--snapshot") {
        Snapshots.render(to: dir)
        exit(0)
    }
    if let dir = value(after: "--render-icon") {
        AppIcon.renderIconset(to: dir)
        exit(0)
    }

    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(options: LaunchOptions(args))
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
