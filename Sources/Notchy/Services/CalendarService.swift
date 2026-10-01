import AppKit
import EventKit
import NotchyCore
import Observation
import SwiftUI

/// Upcoming events from EventKit. Instead of polling, it schedules one wake-up at the next
/// moment something changes (an event entering the 15/5 minute windows, starting, ending) and
/// listens for calendar database changes.
@MainActor @Observable
final class CalendarModel {
    struct Event: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var color: Color
        var location: String?
        var joinURL: URL?
    }

    enum Phase: Equatable {
        case none
        /// Starts in 5–15 minutes: a quiet compact activity.
        case soon(Event)
        /// Starts within 5 minutes (or started in the last 5): high priority, with an alert.
        case imminent(Event)

        var event: Event? {
            switch self {
            case .none: nil
            case .soon(let e), .imminent(let e): e
            }
        }
    }

    enum Access: Equatable { case unknown, notDetermined, denied, granted }

    private(set) var upcoming: [Event] = []
    private(set) var phase = Phase.none
    private(set) var phaseSince = Date()
    private(set) var access = Access.unknown

    @ObservationIgnored var onAlert: ((Event) -> Void)?
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var alerted: Set<String> = []
    @ObservationIgnored private var running = false

    static let soonWindow: TimeInterval = 15 * 60
    static let imminentWindow: TimeInterval = 5 * 60

    func start() {
        guard !running else { return }
        running = true
        updateAccess()
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        if access == .notDetermined {
            requestAccess()
        } else {
            refresh()
        }
    }

    func stop() {
        running = false
        wakeTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        upcoming = []
        phase = .none
    }

    func requestAccess() {
        store.requestFullAccessToEvents { @Sendable [weak self] _, _ in
            Task { @MainActor in
                self?.updateAccess()
                self?.refresh()
            }
        }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notDetermined
        case .denied, .restricted, .writeOnly: access = .denied
        @unknown default: access = .denied
        }
    }

    func refresh() {
        guard running, access == .granted else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(36 * 3600), calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { e in
                Event(id: e.calendarItemIdentifier + "@\(e.startDate.timeIntervalSince1970)",
                      title: e.title ?? "Untitled",
                      start: e.startDate, end: e.endDate,
                      color: Color(nsColor: e.calendar?.color ?? .systemBlue),
                      location: e.location,
                      joinURL: MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes]))
            }
        updatePhase()
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private func updatePhase() {
        let now = Date()
        var next: Phase = .none
        for e in upcoming {
            let dt = e.start.timeIntervalSince(now)
            if dt <= Self.imminentWindow && dt > -Self.imminentWindow {
                next = .imminent(e)
                break
            }
            if dt > Self.imminentWindow && dt <= Self.soonWindow, next == .none {
                next = .soon(e)
            }
        }
        if next != phase {
            phase = next
            phaseSince = now
        }
        if case .imminent(let e) = next, !alerted.contains(e.id) {
            alerted.insert(e.id)
            onAlert?(e)
        }
        scheduleWake(now: now)
    }

    /// Sleep until the next boundary, then re-evaluate. No repeating timer.
    private func scheduleWake(now: Date) {
        wakeTask?.cancel()
        let boundaries = upcoming.flatMap { e in
            [e.start - Self.soonWindow, e.start - Self.imminentWindow, e.start + Self.imminentWindow, e.end]
        }
        guard let next = boundaries.filter({ $0 > now.addingTimeInterval(0.5) }).min() else { return }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.2))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // Demo
    func showDemo(_ events: [Event], phase: Phase) {
        access = .granted
        upcoming = events
        self.phase = phase
    }
}
