import AppKit
import NotchyCore
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable { case general, activities, motion, about }

/// Which tab Settings shows; lets a link or a menu item open a particular one.
@MainActor @Observable
final class SettingsNavigation {
    var tab = SettingsTab.general
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private let navigation = SettingsNavigation()

    func show(settings: AppSettings, model: IslandModel, updates: UpdateService, tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, model: model, updates: updates, navigation: navigation))
            let w = NSWindow(contentViewController: host)
            w.title = "Notchy Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                QALog.log("SETTINGS closed")
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // macOS 14+ activation is cooperative: if the app in front does not yield (Settings opened
        // from a notchy:// link, a script or Shortcuts), the window would appear unfocused and ⌘W
        // would go elsewhere. The user asked for Settings, so insist.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            if !NSApp.isActive {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                self?.window?.makeKeyAndOrderFront(nil)
            }
            QALog.log("SETTINGS focused=\(NSApp.isActive && self?.window?.isKeyWindow == true)")
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let model: IslandModel
    let updates: UpdateService
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralTab(settings: settings, model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ActivitiesTab(settings: settings, model: model)
                .tabItem { Label("Activities", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.activities)
            MotionTab(settings: settings, model: model)
                .tabItem { Label("Motion", systemImage: "wand.and.stars") }
                .tag(SettingsTab.motion)
            AboutTab(settings: settings, updates: updates)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 500, height: 470)
    }
}

private struct GeneralTab: View {
    @Bindable var settings: AppSettings
    let model: IslandModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Open when the pointer rests on the notch", isOn: $settings.openOnHover)
                if settings.openOnHover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $settings.hoverDelay, in: 0.05...0.5)
                            Text("\(Int(settings.hoverDelay * 1000)) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                } else {
                    Text("Click the notch to open it. Hovering only nudges it.").font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Haptic feedback when opening", isOn: $settings.haptics)
                Toggle("Hide from screen sharing and recordings", isOn: $settings.hideFromScreenSharing)
            }
            Section {
                Picker("Show the island on", selection: $settings.screenChoice) {
                    ForEach(AppSettings.ScreenChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("On displays without a notch", selection: $settings.nonNotchMode) {
                    ForEach(AppSettings.NonNotchMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep clear of menus and menu bar icons", isOn: $settings.keepClearOfMenuBar)
                if settings.keepClearOfMenuBar, !model.menuBar.seesMenus {
                    LabeledContent("App menus") {
                        Button("Allow Accessibility…") { model.menuBar.requestAccess() }
                    }
                }
            } header: {
                Text("Display")
            } footer: {
                Text(!settings.keepClearOfMenuBar
                     ? "Live activities use both sides of the notch and may cover menus and icons next to it."
                     : model.menuBar.seesMenus
                     ? "Live activities use only free menu bar space, or show as a thin line under the notch."
                     : "Live activities use only free menu bar space. To use the space left of the notch, Notchy needs to see where app menus end.")
            }
            Section("App") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Open Notchy again from Finder or Spotlight to get back here.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct ActivitiesTab: View {
    @Bindable var settings: AppSettings
    let model: IslandModel

    var body: some View {
        Form {
            Section {
                Toggle("Now Playing", isOn: $settings.nowPlayingEnabled)
                Toggle("Show the track for a moment when it changes", isOn: $settings.peekOnTrackChange)
                    .disabled(!settings.nowPlayingEnabled)
                LabeledContent("Source", value: nowPlayingSource)
            } footer: {
                Text("Works with any app that reports to macOS Now Playing (Music, Spotify, browsers…) through the bundled mediaremote-adapter. If macOS blocks it, Notchy falls back to Music and Spotify only.")
            }
            Section {
                Toggle("Timer", isOn: $settings.timerEnabled)
                Toggle("Play a sound when it ends", isOn: $settings.timerSound).disabled(!settings.timerEnabled)
            } footer: {
                Text("Start one from the island, the menu bar, or a URL: open notchy://timer?minutes=5")
            }
            Section {
                Toggle("Charging and low battery", isOn: $settings.batteryEnabled)
            }
            Section {
                Toggle("Calendar", isOn: $settings.calendarEnabled)
                if settings.calendarEnabled {
                    switch model.calendar.access {
                    case .granted: LabeledContent("Access", value: "Granted")
                    case .denied:
                        LabeledContent("Access") {
                            Button("Open Privacy Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                            }
                        }
                    case .notDetermined, .unknown:
                        LabeledContent("Access") { Button("Allow…") { model.calendar.requestAccess() } }
                    }
                }
            } footer: {
                Text("Shows the next event, counts down from 15 minutes before it, and alerts you at 5.")
            }
            Section {
                Toggle("Volume HUD in the island", isOn: $settings.hudEnabled)
                if settings.hudEnabled {
                    switch model.hud.tapState {
                    case .active: LabeledContent("Media keys", value: "Active")
                    case .needsPermission, .off:
                        LabeledContent("Media keys") {
                            Button("Grant Accessibility…") { model.hud.openAccessibilitySettings() }
                        }
                    }
                    Toggle("Brightness keys too (experimental)", isOn: $settings.hudBrightnessExperimental)
                }
            } footer: {
                Text("Replacing the system HUD means intercepting the media keys, which needs Accessibility access. Volume uses public CoreAudio. Brightness uses Apple's private DisplayServices framework and may break with any macOS update. Keyboard backlight keys are left to macOS.")
            }
        }
        .formStyle(.grouped)
    }

    private var nowPlayingSource: String {
        switch model.nowPlaying.source {
        case .adapter: "System Now Playing (all apps)"
        case .appleScript: "Music and Spotify (fallback)"
        case .demo: "Demo"
        case .none: "Off"
        }
    }
}

private struct MotionTab: View {
    @Bindable var settings: AppSettings
    let model: IslandModel

    var body: some View {
        Form {
            Section("Open") {
                slider("Response", $settings.openResponse, 0.2...0.8, "s")
                slider("Damping", $settings.openDamping, 0.5...1.0, "")
            }
            Section("Close") {
                slider("Response", $settings.closeResponse, 0.2...0.8, "s")
                slider("Damping", $settings.closeDamping, 0.5...1.0, "")
            }
            Section {
                HStack {
                    Button("Preview") {
                        if model.state.isOpen { model.dismiss() } else { model.click() }
                    }
                    Spacer()
                    Button("Reset to defaults") { settings.resetMotion() }
                }
            } footer: {
                Text("Springs like iOS: response is roughly the duration, damping below 1 adds a little overshoot.")
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: "%.2f%@", value.wrappedValue, unit)).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
    }
}

private struct AboutTab: View {
    @Bindable var settings: AppSettings
    let updates: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notchy").font(.title2.weight(.semibold))
                    Text("Version \(updates.current.description)").foregroundStyle(.secondary)
                }
                Spacer()
                UpdateStatus(updates: updates)
            }
            Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
            Text("A Dynamic Island for the Mac notch. No accounts or telemetry; the only request Notchy makes on its own is the update check on GitHub.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Includes mediaremote-adapter").font(.headline)
            Text("Copyright (c) 2025 Jonas van den Berg and contributors. BSD 3-Clause License. github.com/ungive/mediaremote-adapter")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(license).font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
        .padding(20)
    }

    private var license: String {
        guard let url = Bundle.main.url(forResource: "mediaremote-adapter-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "BSD 3-Clause License (see Vendor/mediaremote-adapter/LICENSE)." }
        return text
    }
}

/// The update check and install, at the top of the About tab.
private struct UpdateStatus: View {
    let updates: UpdateService
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch updates.phase {
            case .available(let release):
                Text("Notchy \(release.version.description) is available").font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    Button("What's New") { showNotes = true }
                        .popover(isPresented: $showNotes) { ReleaseNotes(release: release) }
                    Button("Install and Relaunch") { Task { await updates.install() } }
                        .keyboardShortcut(.defaultAction)
                }
            case .installing(let step):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(step).font(.callout) }
            case .checking:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").font(.callout) }
            case .upToDate:
                Text("Notchy is up to date").font(.callout).foregroundStyle(.secondary)
                Button("Check Again") { Task { await updates.check(userInitiated: true) } }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing).frame(maxWidth: 230, alignment: .trailing)
                Button("Try Again") { Task { await updates.check(userInitiated: true) } }
            case .idle:
                Button("Check for Updates") { Task { await updates.check(userInitiated: true) } }
            }
        }
    }
}

private struct ReleaseNotes: View {
    let release: ReleaseInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notchy \(release.version.description)").font(.headline)
            ScrollView {
                Text(release.notes.isEmpty ? "No notes for this release." : release.notes)
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            Link("Open on GitHub", destination: release.pageURL).font(.callout)
        }
        .padding(14)
        .frame(width: 320)
    }
}
