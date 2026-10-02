import Foundation
import NotchyCore
import Observation

/// User preferences, persisted in UserDefaults. Every property writes through on change.
@MainActor @Observable
final class AppSettings {
    enum ScreenChoice: String, CaseIterable, Identifiable {
        case notched, primary, mouse
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notched: "Built-in display (notch)"
            case .primary: "Main display"
            case .mouse: "Display with the pointer"
            }
        }
    }

    enum NonNotchMode: String, CaseIterable, Identifiable {
        case whenActive, always, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .whenActive: "Only when something is happening"
            case .always: "Always (fake notch)"
            case .never: "Never"
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// False for demo/snapshot instances: they must never write to disk.
    @ObservationIgnored let persists: Bool

    private func save(_ value: Any, _ key: String) {
        if persists { defaults.set(value, forKey: key) }
    }

    // General
    var openOnHover: Bool { didSet { save(openOnHover, "openOnHover") } }
    var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay") } }
    var haptics: Bool { didSet { save(haptics, "haptics") } }
    var hideFromScreenSharing: Bool { didSet { save(hideFromScreenSharing, "hideFromScreenSharing") } }
    var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, "showMenuBarIcon") } }
    /// Look for a newer release on GitHub after launch and every 6 hours.
    var checkForUpdates: Bool { didSet { save(checkForUpdates, "checkForUpdates") } }

    // Style
    var islandStyle: IslandStyle { didSet { save(islandStyle.rawValue, "islandStyle") } }
    var phosphor: Phosphor { didSet { save(phosphor.rawValue, "phosphor") } }
    var scanlines: Bool { didSet { save(scanlines, "scanlines") } }
    var theme: IslandTheme { IslandTheme(style: islandStyle, phosphor: phosphor, scanlines: scanlines) }

    // Display
    /// Fit the compact wings into the free menu bar space instead of covering menus and icons.
    var keepClearOfMenuBar: Bool { didSet { save(keepClearOfMenuBar, "keepClearOfMenuBar") } }
    var screenChoice: ScreenChoice { didSet { save(screenChoice.rawValue, "screenChoice") } }
    var nonNotchMode: NonNotchMode { didSet { save(nonNotchMode.rawValue, "nonNotchMode") } }

    // Activities
    var nowPlayingEnabled: Bool { didSet { save(nowPlayingEnabled, "nowPlayingEnabled") } }
    var peekOnTrackChange: Bool { didSet { save(peekOnTrackChange, "peekOnTrackChange") } }
    var timerEnabled: Bool { didSet { save(timerEnabled, "timerEnabled") } }
    var timerSound: Bool { didSet { save(timerSound, "timerSound") } }
    /// Pomodoro lengths, in minutes.
    var pomodoroFocus: Int { didSet { save(pomodoroFocus, "pomodoroFocus") } }
    var pomodoroBreak: Int { didSet { save(pomodoroBreak, "pomodoroBreak") } }
    var pomodoroLongBreak: Int { didSet { save(pomodoroLongBreak, "pomodoroLongBreak") } }
    var pomodoroPlan: PomodoroPlan {
        PomodoroPlan(focus: TimeInterval(pomodoroFocus * 60), shortBreak: TimeInterval(pomodoroBreak * 60),
                     longBreak: TimeInterval(pomodoroLongBreak * 60), rounds: 4)
    }
    /// Shelf page: files dropped on the notch, and clipboard history.
    var shelfEnabled: Bool { didSet { save(shelfEnabled, "shelfEnabled") } }
    var clipboardHistory: Bool { didSet { save(clipboardHistory, "clipboardHistory") } }
    var batteryEnabled: Bool { didSet { save(batteryEnabled, "batteryEnabled") } }
    var calendarEnabled: Bool { didSet { save(calendarEnabled, "calendarEnabled") } }
    var hudEnabled: Bool { didSet { save(hudEnabled, "hudEnabled") } }
    /// Brightness keys need the private DisplayServices framework. Off unless the user opts in.
    var hudBrightnessExperimental: Bool { didSet { save(hudBrightnessExperimental, "hudBrightnessExperimental") } }

    // Motion (tunable from the Settings window's Motion section)
    var openResponse: Double { didSet { save(openResponse, "openResponse") } }
    var openDamping: Double { didSet { save(openDamping, "openDamping") } }
    var closeResponse: Double { didSet { save(closeResponse, "closeResponse") } }
    var closeDamping: Double { didSet { save(closeDamping, "closeDamping") } }

    static let motionDefaults = (openResponse: 0.42, openDamping: 0.80, closeResponse: 0.36, closeDamping: 0.90)

    init(defaults: UserDefaults = .standard, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        func double(_ k: String, _ d: Double) -> Double { defaults.object(forKey: k) as? Double ?? d }
        func int(_ k: String, _ d: Int) -> Int { defaults.object(forKey: k) as? Int ?? d }
        openOnHover = bool("openOnHover", true)
        hoverDelay = double("hoverDelay", 0.12)
        haptics = bool("haptics", true)
        hideFromScreenSharing = bool("hideFromScreenSharing", true)
        showMenuBarIcon = bool("showMenuBarIcon", true)
        checkForUpdates = bool("checkForUpdates", true)
        islandStyle = IslandStyle(rawValue: defaults.string(forKey: "islandStyle") ?? "") ?? .classic
        phosphor = Phosphor(rawValue: defaults.string(forKey: "phosphor") ?? "") ?? .color
        scanlines = bool("scanlines", true)
        keepClearOfMenuBar = bool("keepClearOfMenuBar", true)
        screenChoice = ScreenChoice(rawValue: defaults.string(forKey: "screenChoice") ?? "") ?? .notched
        nonNotchMode = NonNotchMode(rawValue: defaults.string(forKey: "nonNotchMode") ?? "") ?? .whenActive
        nowPlayingEnabled = bool("nowPlayingEnabled", true)
        peekOnTrackChange = bool("peekOnTrackChange", true)
        timerEnabled = bool("timerEnabled", true)
        timerSound = bool("timerSound", true)
        pomodoroFocus = int("pomodoroFocus", 25)
        pomodoroBreak = int("pomodoroBreak", 5)
        pomodoroLongBreak = int("pomodoroLongBreak", 15)
        shelfEnabled = bool("shelfEnabled", true)
        clipboardHistory = bool("clipboardHistory", true)
        batteryEnabled = bool("batteryEnabled", true)
        calendarEnabled = bool("calendarEnabled", true)
        hudEnabled = bool("hudEnabled", false)
        hudBrightnessExperimental = bool("hudBrightnessExperimental", false)
        openResponse = double("openResponse", Self.motionDefaults.openResponse)
        openDamping = double("openDamping", Self.motionDefaults.openDamping)
        closeResponse = double("closeResponse", Self.motionDefaults.closeResponse)
        closeDamping = double("closeDamping", Self.motionDefaults.closeDamping)
    }

    func resetMotion() {
        openResponse = Self.motionDefaults.openResponse
        openDamping = Self.motionDefaults.openDamping
        closeResponse = Self.motionDefaults.closeResponse
        closeDamping = Self.motionDefaults.closeDamping
    }

    /// A throwaway instance for demos and snapshots, so they never touch the user's defaults.
    static func ephemeral() -> AppSettings {
        // Reads nothing the user set (an unused suite) and writes nothing.
        let s = AppSettings(defaults: UserDefaults(suiteName: "notchy.ephemeral") ?? .standard, persists: false)
        s.hideFromScreenSharing = false
        s.hudEnabled = true
        return s
    }
}
