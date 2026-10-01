import Foundation
import NotchyCore

/// Test-only trace for the QA harness. Silent unless launched with `NOTCHY_QA_LOG=1`;
/// then prints one line per event to stdout so scripted tests can assert on exact state.
enum QALog {
    static let enabled = ProcessInfo.processInfo.environment["NOTCHY_QA_LOG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("QA \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(message())")
        fflush(stdout)
    }

    static func describe(_ s: IslandState) -> String {
        switch s {
        case .idle: "idle"
        case .compact(let k): "compact:\(k.rawValue)"
        case .expanded(.home): "expanded:home"
        case .expanded(.activity(let k)): "expanded:\(k.rawValue)"
        case .peek(let k): "peek:\(k.rawValue)"
        }
    }
}
