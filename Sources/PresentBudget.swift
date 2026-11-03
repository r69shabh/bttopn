import Foundation

// MARK: - Present Budget
//
// Circuit breaker for presentSystemModalTouchBar calls. Every present
// re-lays-out the whole Control Strip and, past some threshold, macOS stops
// accepting this client's requests — observed in practice as "keys work for
// N Raycast invocations, then never come back until the app re-registers".
// The old behaviour (re-present every 0.5s + 5 staggered timers per app
// switch) was exactly the hammer that trips it.
//
// Policy: consecutive FAILED presents (attempt, no successful visible
// result) trip a breaker at `maxConsecutiveFailures`. Until `reset()` is
// called — by an explicit user toggle, wake-from-sleep, KVO observing the
// bar becoming visible, or an app restart — the manager stops presenting
// entirely instead of deepening the ban.

enum PresentBudget {

    static let maxConsecutiveFailures = 8

    struct State: Equatable {
        private(set) var failures = 0
        private(set) var suspended = false

        /// Record one present attempt. Suspends the budget once the
        /// failure threshold is reached.
        mutating func noteAttempt() {
            failures += 1
            if failures >= PresentBudget.maxConsecutiveFailures {
                suspended = true
            }
        }

        /// Clear back to zero — called when the bar is observed visible,
        /// on explicit user action, and on wake.
        mutating func reset() {
            failures = 0
            suspended = false
        }
    }
}
