import AppKit
import IOKit.ps
import Observation

/// Internal battery state from IOKit power-source notifications (never polled).
/// Shows a short banner when power is connected or the battery gets low.
@MainActor @Observable
final class BatteryModel {
    struct Banner: Equatable {
        enum Kind: Equatable { case charging, connected, low }
        var kind: Kind
        var at: Date
    }

    /// nil on Macs without a battery.
    private(set) var level: Int?
    private(set) var isCharging = false
    private(set) var onAC = false
    private(set) var banner: Banner?

    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var lowAlerted: Set<Int> = []

    func start() {
        guard source == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource(powerSourcesChanged, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
        refresh(initial: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        hideTask?.cancel()
        banner = nil
    }

    func refresh(initial: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        var newLevel: Int?
        var charging = false
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            newLevel = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let ac = providing == kIOPSACPowerValue
        let wasAC = onAC

        level = newLevel
        isCharging = charging
        onAC = ac
        guard let lvl = newLevel, !initial else { return }

        if ac && !wasAC {
            lowAlerted.removeAll()
            show(charging ? .charging : .connected)
        } else if !ac {
            for threshold in [20, 10] where lvl <= threshold && !lowAlerted.contains(threshold) {
                lowAlerted.insert(threshold)
                show(.low)
                break
            }
        }
    }

    private func show(_ kind: Banner.Kind) {
        banner = Banner(kind: kind, at: Date())
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .low ? 5 : 3.5))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    // Demo
    func showDemo(level: Int, charging: Bool, banner kind: Banner.Kind?) {
        self.level = level
        isCharging = charging
        onAC = charging
        banner = kind.map { Banner(kind: $0, at: Date()) }
    }
}

/// C callback; the source is on the main run loop.
private func powerSourcesChanged(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let model = Unmanaged<BatteryModel>.fromOpaque(ctx).takeUnretainedValue()
    MainActor.assumeIsolated { model.refresh(initial: false) }
}
