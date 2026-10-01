import Foundation
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

    // General
    var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var hideFromScreenSharing: Bool { didSet { defaults.set(hideFromScreenSharing, forKey: "hideFromScreenSharing") } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }

    // Display
    var screenChoice: ScreenChoice { didSet { defaults.set(screenChoice.rawValue, forKey: "screenChoice") } }
    var nonNotchMode: NonNotchMode { didSet { defaults.set(nonNotchMode.rawValue, forKey: "nonNotchMode") } }

    // Activities
    var nowPlayingEnabled: Bool { didSet { defaults.set(nowPlayingEnabled, forKey: "nowPlayingEnabled") } }
    var peekOnTrackChange: Bool { didSet { defaults.set(peekOnTrackChange, forKey: "peekOnTrackChange") } }
    var timerEnabled: Bool { didSet { defaults.set(timerEnabled, forKey: "timerEnabled") } }
    var timerSound: Bool { didSet { defaults.set(timerSound, forKey: "timerSound") } }
    var batteryEnabled: Bool { didSet { defaults.set(batteryEnabled, forKey: "batteryEnabled") } }
    var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: "calendarEnabled") } }
    var hudEnabled: Bool { didSet { defaults.set(hudEnabled, forKey: "hudEnabled") } }
    /// Brightness keys need the private DisplayServices framework. Off unless the user opts in.
    var hudBrightnessExperimental: Bool { didSet { defaults.set(hudBrightnessExperimental, forKey: "hudBrightnessExperimental") } }

    // Motion (tunable from the Settings window's Motion section)
    var openResponse: Double { didSet { defaults.set(openResponse, forKey: "openResponse") } }
    var openDamping: Double { didSet { defaults.set(openDamping, forKey: "openDamping") } }
    var closeResponse: Double { didSet { defaults.set(closeResponse, forKey: "closeResponse") } }
    var closeDamping: Double { didSet { defaults.set(closeDamping, forKey: "closeDamping") } }

    static let motionDefaults = (openResponse: 0.42, openDamping: 0.80, closeResponse: 0.36, closeDamping: 0.90)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        func double(_ k: String, _ d: Double) -> Double { defaults.object(forKey: k) as? Double ?? d }
        openOnHover = bool("openOnHover", true)
        hoverDelay = double("hoverDelay", 0.12)
        haptics = bool("haptics", true)
        hideFromScreenSharing = bool("hideFromScreenSharing", true)
        showMenuBarIcon = bool("showMenuBarIcon", true)
        screenChoice = ScreenChoice(rawValue: defaults.string(forKey: "screenChoice") ?? "") ?? .notched
        nonNotchMode = NonNotchMode(rawValue: defaults.string(forKey: "nonNotchMode") ?? "") ?? .whenActive
        nowPlayingEnabled = bool("nowPlayingEnabled", true)
        peekOnTrackChange = bool("peekOnTrackChange", true)
        timerEnabled = bool("timerEnabled", true)
        timerSound = bool("timerSound", true)
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
        let d = UserDefaults(suiteName: "notchy.ephemeral.\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.hideFromScreenSharing = false
        s.hudEnabled = true
        return s
    }
}
