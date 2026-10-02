import AppKit
import NotchyCore
import Observation

/// A single countdown. No ticking timer runs: views draw the countdown with
/// `Text(timerInterval:)` and one sleeping task fires at the end.
@MainActor @Observable
final class TimerModel {
    private(set) var endDate: Date?
    private(set) var pausedRemaining: TimeInterval?
    private(set) var duration: TimeInterval = 0
    private(set) var finishedAt: Date?
    private(set) var startedAt = Date()
    /// Set while a Pomodoro is running: which phase, under which plan.
    private(set) var pomodoro: (phase: PomodoroPhase, plan: PomodoroPlan)?

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }
    var isDone: Bool { finishedAt != nil }
    var isActive: Bool { isRunning || isPaused || isDone }

    @ObservationIgnored var playSound = true
    @ObservationIgnored var onFinish: (() -> Void)?
    /// A Pomodoro phase ended and the next one started.
    @ObservationIgnored var onPhaseChange: ((PomodoroPhase) -> Void)?
    @ObservationIgnored private var fireTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func start(_ seconds: TimeInterval) {
        cancel()
        begin(seconds)
    }

    /// Focus and break in turns until cancelled; each phase starts the next.
    func startPomodoro(_ plan: PomodoroPlan) {
        cancel()
        pomodoro = (.focus(round: 1), plan)
        begin(plan.focus)
    }

    /// Ends the current Pomodoro phase now and starts the next.
    func skipPhase() {
        guard let p = pomodoro else { return }
        advance(from: p.phase, plan: p.plan, sound: false)
    }

    private func begin(_ seconds: TimeInterval) {
        fireTask?.cancel()
        dismissTask?.cancel()
        pausedRemaining = nil
        finishedAt = nil
        duration = seconds
        startedAt = Date()
        endDate = Date().addingTimeInterval(seconds)
        schedule()
    }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let p = pausedRemaining { return p }
        if let e = endDate { return max(0, e.timeIntervalSince(now)) }
        return 0
    }

    /// Fraction elapsed, 0...1.
    func progress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return isDone ? 1 : 0 }
        return isDone ? 1 : min(1, max(0, 1 - remaining(at: now) / duration))
    }

    func pause() {
        guard let e = endDate else { return }
        pausedRemaining = max(0, e.timeIntervalSinceNow)
        endDate = nil
        fireTask?.cancel()
    }

    func resume() {
        guard let p = pausedRemaining else { return }
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(p)
        schedule()
    }

    func add(_ seconds: TimeInterval) {
        if let p = pausedRemaining {
            pausedRemaining = p + seconds
        } else if let e = endDate {
            endDate = e.addingTimeInterval(seconds)
            schedule()
        } else {
            start(seconds)
            return
        }
        duration += seconds
    }

    func cancel() {
        fireTask?.cancel()
        dismissTask?.cancel()
        endDate = nil
        pausedRemaining = nil
        finishedAt = nil
        pomodoro = nil
    }

    private func schedule() {
        fireTask?.cancel()
        guard let e = endDate else { return }
        fireTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, e.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        if let p = pomodoro {
            advance(from: p.phase, plan: p.plan, sound: true)
            return
        }
        endDate = nil
        finishedAt = Date()
        if playSound { NSSound(named: "Glass")?.play() }
        onFinish?()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    private func advance(from phase: PomodoroPhase, plan: PomodoroPlan, sound: Bool) {
        let next = plan.next(after: phase)
        pomodoro = (next, plan)
        begin(plan.duration(of: next))
        if sound, playSound { NSSound(named: next.isBreak ? "Glass" : "Hero")?.play() }
        onPhaseChange?(next)
    }

    // Demo
    func showDemo(remaining: TimeInterval, total: TimeInterval, pomodoro phase: PomodoroPhase? = nil) {
        pomodoro = phase.map { ($0, PomodoroPlan()) }
        duration = total
        endDate = Date().addingTimeInterval(remaining)
        startedAt = Date().addingTimeInterval(remaining - total)
    }
}
