@testable import Debounce
import Testing

/// Deterministic tests of the debounce state machine. Time is in abstract ticks; interval = 100.
@Suite struct DebounceMachineTests {
    func machine(_ edges: TriggerEdges = .trailing) -> _DebounceMachine<String> {
        _DebounceMachine(interval: 100, edges: edges)
    }

    @Test func trailingRunsLastValueAfterQuietPeriod() {
        var m = machine()
        #expect(m.send("a", now: 0) == true, "the first value starts a worker")
        #expect(m.send("b", now: 50) == false, "the worker is already running")
        #expect(m.next(now: 50) == .sleep(until: 150), "each value extends the burst")
        #expect(m.next(now: 150) == .run("b"))
        #expect(m.next(now: 160) == .exit)
        #expect(m.isWorkerActive == false)
    }

    @Test func trailingWaitsForEarlyWakeUps() {
        var m = machine()
        _ = m.send("a", now: 0)
        #expect(m.next(now: 99) == .sleep(until: 100))
        #expect(m.next(now: 100) == .run("a"))
    }

    @Test func valueSentWhileActionRunsWaitsForTheQuietPeriod() {
        var m = machine()
        _ = m.send("a", now: 0)
        #expect(m.next(now: 100) == .run("a"))
        // the action is running; a new burst starts
        #expect(m.send("b", now: 120) == false)
        #expect(m.send("c", now: 130) == false)
        // the action returns before the burst is over
        #expect(m.next(now: 150) == .sleep(until: 230))
        #expect(m.next(now: 230) == .run("c"))
        #expect(m.next(now: 240) == .exit)
    }

    @Test func valueDueWhileActionRunsStartsRightAfterIt() {
        var m = machine()
        _ = m.send("a", now: 0)
        #expect(m.next(now: 100) == .run("a"))
        _ = m.send("b", now: 120)
        // slow action: returns long after the burst of "b" ended (at 220)
        #expect(m.next(now: 500) == .run("b"))
        #expect(m.next(now: 510) == .exit)
    }

    @Test func leadingRunsFirstValueAndDropsTheRest() {
        var m = machine(.leading)
        #expect(m.send("a", now: 0) == true)
        #expect(m.next(now: 0) == .run("a"))
        _ = m.send("b", now: 50)
        _ = m.send("c", now: 120)
        #expect(m.next(now: 130) == .sleep(until: 220), "dropped values still extend the burst")
        #expect(m.next(now: 220) == .exit)
        // a new burst
        #expect(m.send("d", now: 300) == true)
        #expect(m.next(now: 300) == .run("d"))
    }

    @Test func leadingAndTrailingRunsSingleValueOnce() {
        var m = machine([.leading, .trailing])
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        #expect(m.next(now: 10) == .sleep(until: 100))
        #expect(m.next(now: 100) == .exit)
    }

    @Test func leadingAndTrailingRunsFirstAndLast() {
        var m = machine([.leading, .trailing])
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        _ = m.send("b", now: 10)
        _ = m.send("c", now: 20)
        #expect(m.next(now: 30) == .sleep(until: 120))
        #expect(m.next(now: 120) == .run("c"))
        #expect(m.next(now: 130) == .exit)
    }

    @Test func burstThatEndedBeforeTheWorkerWokeIsStillDelivered() {
        // "a" is due at 100, but the worker is late; "b" starts a new burst at 150.
        var m = machine()
        _ = m.send("a", now: 0)
        #expect(m.send("b", now: 150) == false)
        #expect(m.next(now: 160) == .run("a"))
        #expect(m.next(now: 170) == .sleep(until: 250))
        #expect(m.next(now: 250) == .run("b"))
    }

    @Test func onlyTheLatestDueValueIsKept() {
        var m = machine([.leading, .trailing])
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        // while "a" runs, a burst ends ("b" due at 110) and a new one starts ("c" on its leading edge)
        _ = m.send("b", now: 10)
        _ = m.send("c", now: 200)
        #expect(m.next(now: 210) == .run("c"))
    }

    @Test func resetDropsEverything() {
        var m = machine()
        _ = m.send("a", now: 0)
        m.reset()
        #expect(m.isWorkerActive == false)
        #expect(m.next(now: 1_000) == .exit)
        #expect(m.send("b", now: 1_000) == true, "a reset machine starts a new worker")
    }

    @Test func deadlineSaturatesInsteadOfOverflowing() {
        var m = _DebounceMachine<Int>(interval: .max, edges: .trailing)
        _ = m.send(1, now: 10)
        #expect(m.next(now: 20) == .sleep(until: .max))
    }
}

extension _Step: Equatable where Value: Equatable {
    public static func == (lhs: _Step<Value>, rhs: _Step<Value>) -> Bool {
        switch (lhs, rhs) {
        case (.run(let a), .run(let b)): a == b
        case (.sleep(let a), .sleep(let b)): a == b
        case (.exit, .exit): true
        default: false
        }
    }
}
