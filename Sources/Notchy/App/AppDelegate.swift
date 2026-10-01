import AppKit
import NotchyCore

struct LaunchOptions {
    var demo: DemoScenario?
    var printWindowID = false

    init(_ args: [String]) {
        if let i = args.firstIndex(of: "--demo") {
            demo = args.indices.contains(i + 1) ? DemoScenario(rawValue: args[i + 1]) ?? .expanded : .expanded
        }
        printWindowID = args.contains("--print-window")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private let settings: AppSettings
    private var model: IslandModel!
    private var controller: IslandController!
    private var statusItem: NSStatusItem?
    private let settingsWindow = SettingsWindowController()
    private var sigterm: DispatchSourceSignal?

    init(options: LaunchOptions) {
        self.options = options
        // Demo runs never read or write the user's preferences.
        settings = options.demo == nil ? AppSettings() : .ephemeral()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` / logout: quit normally so the adapter child process is stopped too.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        term.resume()
        sigterm = term

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        model = IslandModel(settings: settings, metrics: IslandController.metrics(for: screen))
        if let demo = options.demo {
            Demo.apply(demo, to: model)
        } else {
            model.startServices()
        }
        controller = IslandController(model: model, settings: settings, demo: options.demo != nil)
        let m = model.metrics
        QALog.log("LAUNCH screen=\(Int(m.screenFrame.width))x\(Int(m.screenFrame.height)) hasNotch=\(m.hasNotch) notchSize=\(Int(m.notchSize.width))x\(Int(m.notchSize.height)) panel=\(Int(controller.panel.frame.minX)),\(Int(controller.panel.frame.minY)) \(Int(controller.panel.frame.width))x\(Int(controller.panel.frame.height)) window=\(controller.panel.windowNumber)")
        if options.printWindowID {
            print("NOTCHY_WINDOW_ID=\(controller.panel.windowNumber)")
            fflush(stdout)
        }
        // (Temporary QA experiment switch: NOTCHY_QA_NO_MAINMENU=1 skips the hidden main menu.)
        if ProcessInfo.processInfo.environment["NOTCHY_QA_NO_MAINMENU"] != "1" { NSApp.mainMenu = Self.mainMenu() }
        observeChanges({ [settings] in settings.showMenuBarIcon }) { [weak self] show in
            self?.setStatusItem(visible: show)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.nowPlaying.stop()
        model?.hud.disableKeys()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { QALog.log("URL \(url.absoluteString)") }
        for link in urls.compactMap(DeepLink.init(url:)) { handle(link) }
    }

    /// Opening the app again (Finder, Spotlight) shows Settings, the way back if the menu bar
    /// icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func handle(_ link: DeepLink) {
        switch link {
        case .startTimer(let seconds): model.timer.start(seconds)
        case .cancelTimer: model.timer.cancel()
        case .open: model.click()
        case .settings: openSettings()
        }
    }

    // MARK: Menu bar

    private func setStatusItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.statusIcon()
            item.button?.toolTip = "Notchy"
            let menu = buildMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) { QALog.log("MENU opened") }



    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Open Island", #selector(openIsland)))
        let timer = NSMenuItem(title: "Start Timer", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for minutes in [1, 5, 10, 15, 25, 60] {
            let i = menuItem(minutes < 60 ? "\(minutes) min" : "1 hour", #selector(startTimer(_:)))
            i.tag = minutes
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(menuItem("Cancel Timer", #selector(cancelTimer)))
        timer.submenu = sub
        menu.addItem(timer)
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openIsland() { model.click() }
    @objc private func startTimer(_ sender: NSMenuItem) { model.timer.start(TimeInterval(sender.tag * 60)) }
    @objc private func cancelTimer() { model.timer.cancel() }
    @objc private func openSettings() {
        QALog.log("SETTINGS shown")
        settingsWindow.show(settings: settings, model: model)
    }

    /// Not shown (Notchy has no menu bar of its own), but it gives the Settings window the standard
    /// shortcuts while Notchy is in front: ⌘W, ⌘M, ⌘Q, ⌘, and text editing.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Notchy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Notchy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for (title, sub) in [("Notchy", app), ("Edit", edit), ("Window", window)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            main.addItem(item)
        }
        return main
    }

    /// A screen outline with the island at the top, as a template image.
    private static func statusIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2, width: 17, height: 12.5), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.4
            screen.stroke()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 1.3, width: 8, height: 4.2), xRadius: 2.1, yRadius: 2.1).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
