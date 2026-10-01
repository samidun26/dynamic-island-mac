import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import Observation

/// Volume / brightness HUD shown in the island instead of the system's.
///
/// The system HUD can only be suppressed by *consuming* the media key in an active
/// `CGEventTap`, which needs Accessibility permission. Once consumed, Notchy must apply the change
/// itself: volume through public CoreAudio, brightness only through the private DisplayServices
/// framework (opt-in). Anything Notchy cannot apply is passed through to macOS untouched.
@MainActor @Observable
final class HUDModel {
    enum Kind: Equatable { case volume, brightness }
    enum TapState: Equatable { case off, needsPermission, active }

    struct Current: Equatable {
        var kind: Kind
        var level: Double
        var muted: Bool
        var at: Date
    }

    private(set) var current: Current?
    private(set) var tapState = TapState.off
    /// Mirrors the output device, for the expanded Now Playing slider.
    private(set) var volume: Double = 0.5
    private(set) var muted = false
    private(set) var brightnessAvailable = false

    @ObservationIgnored let audio = SystemAudio()
    @ObservationIgnored private var tap: MediaKeyTap?
    @ObservationIgnored private var brightness: DisplayBrightness?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var axObserver: NSObjectProtocol?
    @ObservationIgnored private var wantsTap = false

    func startVolumeMirror() {
        syncVolume()
        audio.observe { [weak self] in self?.syncVolume() }
    }

    private func syncVolume() {
        volume = audio.volume ?? volume
        muted = audio.isMuted
    }

    /// Volume set from the island's own slider: no HUD (the slider is the feedback).
    func setVolume(_ v: Double) {
        audio.setVolume(v)
        if v > 0, audio.isMuted { audio.setMuted(false) }
        syncVolume()
    }

    // MARK: Key tap

    func enableKeys(brightness useBrightness: Bool) {
        wantsTap = true
        brightness = useBrightness ? (brightness ?? DisplayBrightness()) : nil
        brightnessAvailable = brightness?.isAvailable ?? false
        if tap == nil { installTap(prompt: true) }
    }

    func disableKeys() {
        wantsTap = false
        tap?.stop()
        tap = nil
        tapState = .off
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
    }

    private func installTap(prompt: Bool) {
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        let t = MediaKeyTap { [weak self] code, down, isRepeat, mods in
            self?.handleKey(code, down: down, isRepeat: isRepeat, mods: mods) ?? false
        }
        if trusted, t.start() {
            tap = t
            tapState = .active
            return
        }
        tapState = .needsPermission
        // The Accessibility list posts this when it changes; retry then instead of polling.
        if axObserver == nil {
            axObserver = DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self, self.wantsTap, self.tap == nil else { return }
                    self.installTap(prompt: false)
                }
            }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Returns true when the key was handled and must be swallowed (which hides the system HUD).
    private func handleKey(_ code: Int32, down: Bool, isRepeat: Bool, mods: NSEvent.ModifierFlags) -> Bool {
        let fine = mods.contains(.option) && mods.contains(.shift)
        let steps: Double = fine ? 64 : 16
        func stepped(_ v: Double, _ up: Bool) -> Double {
            min(1, max(0, ((v * steps).rounded() + (up ? 1 : -1)) / steps))
        }
        switch code {
        case MediaKey.soundUp, MediaKey.soundDown:
            guard audio.canSetVolume, let v = audio.volume else { return false }
            if down {
                let nv = stepped(v, code == MediaKey.soundUp)
                audio.setVolume(nv)
                if audio.isMuted, code == MediaKey.soundUp { audio.setMuted(false) }
                syncVolume()
                show(.volume, level: nv, muted: audio.isMuted)
            }
            return true
        case MediaKey.mute:
            guard audio.canSetVolume else { return false }
            if down && !isRepeat {
                audio.setMuted(!audio.isMuted)
                syncVolume()
                show(.volume, level: volume, muted: muted)
            }
            return true
        case MediaKey.brightnessUp, MediaKey.brightnessDown:
            guard let b = brightness, b.isAvailable, let v = b.level() else { return false }
            if down {
                let nv = stepped(v, code == MediaKey.brightnessUp)
                b.setLevel(nv)
                show(.brightness, level: nv, muted: false)
            }
            return true
        default:
            return false
        }
    }

    func show(_ kind: Kind, level: Double, muted: Bool) {
        current = Current(kind: kind, level: level, muted: muted, at: current?.kind == kind ? current!.at : Date())
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

enum MediaKey {
    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    static let soundUp: Int32 = 0
    static let soundDown: Int32 = 1
    static let brightnessUp: Int32 = 2
    static let brightnessDown: Int32 = 3
    static let mute: Int32 = 7
}

/// Active (consuming) tap for NX_SYSDEFINED media-key events.
@MainActor
final class MediaKeyTap {
    typealias Handler = @MainActor (_ code: Int32, _ down: Bool, _ isRepeat: Bool, _ mods: NSEvent.ModifierFlags) -> Bool
    private let handler: Handler
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    init(handler: @escaping Handler) { self.handler = handler }

    func start() -> Bool {
        let systemDefined: CGEventMask = 1 << 14 // NX_SYSDEFINED
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: mediaKeyTapCallback,
            userInfo: ref) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        source = src
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let data1 = ns.data1
        let code = Int32((data1 & 0xFFFF_0000) >> 16)
        let flags = data1 & 0x0000_FFFF
        let down = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = (flags & 0x1) == 1
        return handler(code, down, isRepeat, ns.modifierFlags)
    }
}

/// C callback (must not capture or carry actor isolation). The tap's run loop source is on the
/// main run loop, so it runs on the main thread.
private func mediaKeyTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    let consume = MainActor.assumeIsolated { tap.process(type, event) }
    return consume ? nil : Unmanaged.passUnretained(event)
}

// MARK: - CoreAudio

/// Default output device volume and mute through public CoreAudio.
@MainActor
final class SystemAudio {
    private var device: AudioDeviceID?
    private var onChange: (@MainActor () -> Void)?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static let volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    private static let muteAddress = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
    private static let defaultDeviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice)

    private func currentDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = Self.defaultDeviceAddress
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    var volume: Double? {
        guard let dev = currentDevice() else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = Self.volumeAddress
        guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return Double(v)
    }

    var canSetVolume: Bool {
        guard let dev = currentDevice() else { return false }
        var addr = Self.volumeAddress
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(dev, &addr) && AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    func setVolume(_ v: Double) {
        guard let dev = currentDevice() else { return }
        var value = Float32(min(1, max(0, v)))
        var addr = Self.volumeAddress
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    var isMuted: Bool {
        guard let dev = currentDevice() else { return false }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = Self.muteAddress
        guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr else { return false }
        return m != 0
    }

    func setMuted(_ muted: Bool) {
        guard let dev = currentDevice() else { return }
        var m = UInt32(muted ? 1 : 0)
        var addr = Self.muteAddress
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    /// Calls `onChange` when the default device, its volume or its mute state changes.
    func observe(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.rebindDevice()
                self?.onChange?()
            }
        }
        deviceListener = block
        var addr = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        rebindDevice()
    }

    private func rebindDevice() {
        let new = currentDevice()
        guard new != device else { return }
        if let old = device, let l = valueListener {
            var a = Self.volumeAddress, b = Self.muteAddress
            AudioObjectRemovePropertyListenerBlock(old, &a, .main, l)
            AudioObjectRemovePropertyListenerBlock(old, &b, .main, l)
        }
        device = new
        guard let dev = new else { return }
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        valueListener = l
        var a = Self.volumeAddress, b = Self.muteAddress
        if AudioObjectHasProperty(dev, &a) { AudioObjectAddPropertyListenerBlock(dev, &a, .main, l) }
        if AudioObjectHasProperty(dev, &b) { AudioObjectAddPropertyListenerBlock(dev, &b, .main, l) }
    }
}

// MARK: - Brightness (private API, opt-in)

/// Built-in display brightness through the private DisplayServices framework. There is no public
/// API for this on Apple silicon. Loaded with dlopen so a missing symbol only disables the feature.
@MainActor
final class DisplayBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private let getFn: GetFn?
    private let setFn: SetFn?

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getFn = h.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        setFn = h.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
    }

    private var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    var isAvailable: Bool { getFn != nil && setFn != nil && builtInDisplay != nil }

    func level() -> Double? {
        guard let getFn, let d = builtInDisplay else { return nil }
        var v: Float = 0
        return getFn(d, &v) == 0 ? Double(v) : nil
    }

    func setLevel(_ v: Double) {
        guard let setFn, let d = builtInDisplay else { return }
        _ = setFn(d, Float(min(1, max(0, v))))
    }
}
