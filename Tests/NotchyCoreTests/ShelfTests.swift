import XCTest
@testable import NotchyCore

final class ShelfTests: XCTestCase {
    func testPomodoroCycle() {
        let plan = PomodoroPlan(focus: 1500, shortBreak: 300, longBreak: 900, rounds: 4)
        var phase = PomodoroPhase.focus(round: 1)
        var seen: [PomodoroPhase] = [phase]
        for _ in 0..<8 { phase = plan.next(after: phase); seen.append(phase) }
        XCTAssertEqual(seen, [.focus(round: 1), .shortBreak(after: 1), .focus(round: 2), .shortBreak(after: 2),
                              .focus(round: 3), .shortBreak(after: 3), .focus(round: 4), .longBreak(after: 4), .focus(round: 1)])
        XCTAssertEqual(plan.duration(of: .longBreak(after: 4)), 900)
        XCTAssertEqual(PomodoroPhase.focus(round: 2).title(rounds: 4), "Focus 2 of 4")
        XCTAssertTrue(PomodoroPhase.shortBreak(after: 1).isBreak)
    }

    func testClipboardSkipsPasswordManagers() {
        XCTAssertTrue(ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"]))
        XCTAssertFalse(ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text", "com.agilebits.onepassword"]))
        XCTAssertFalse(ClipboardPolicy.shouldRecord(types: ["org.nspasteboard.TransientType"]))
    }

    func testHistoryKeepsPinsAndCapsTheRest() {
        var h = ClipHistory(limit: 3)
        h.add("one"); h.add("two")
        h.togglePin(h.items[1].id)            // pin "one"
        h.add("three"); h.add("four"); h.add("five")
        XCTAssertEqual(h.items.map(\.text), ["five", "four", "three", "one"])
        XCTAssertEqual(h.pinned.map(\.text), ["one"])
        h.add("three")                         // copied again: moves to the top
        XCTAssertEqual(h.items.first?.text, "three")
        XCTAssertEqual(h.items.filter { $0.text == "three" }.count, 1)
        h.add("   \n ")                        // blank copies are ignored
        XCTAssertEqual(h.items.first?.text, "three")
        h.clear()
        XCTAssertEqual(h.items.map(\.text), ["one"])
        h.add(String(repeating: "x", count: 50_000))
        XCTAssertEqual(h.items.first?.text.count, ClipboardPolicy.maxLength)
    }

    func testQuickActionKinds() {
        XCTAssertEqual(ClipKind.detect("https://notch.example/a?b=1"), .link(URL(string: "https://notch.example/a?b=1")!))
        XCTAssertEqual(ClipKind.detect("ftp://notch.example"), .text)
        XCTAssertEqual(ClipKind.detect("javascript:alert(1)"), .text)
        XCTAssertEqual(ClipKind.detect("someone@example.com"), .email)
        XCTAssertEqual(ClipKind.detect("#ff8000"), .color(r: 1, g: 128.0 / 255, b: 0))
        XCTAssertEqual(ClipKind.detect("#fff"), .color(r: 1, g: 1, b: 1))
        XCTAssertEqual(ClipKind.detect("two\nlines https://x.example"), .text)
        XCTAssertEqual(ClipKind.detect("just words"), .text)
    }

    func testShelfPageComesAfterHome() {
        let e = [ActivityEntry(kind: .timer, priority: ActivityPriority.timer, since: Date())]
        XCTAssertEqual(ActivityQueue(entries: e, shelf: true).pages, [.activity(.timer), .home, .shelf])
        XCTAssertEqual(ActivityQueue(entries: e).pages, [.activity(.timer), .home])
    }
}
