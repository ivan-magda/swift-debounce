@testable import Debounce
import Testing

/// Deterministic tests of the throttle state machine. Time is in abstract ticks; interval = 100.
@Suite struct ThrottleMachineTests {
    func machine(_ edges: TriggerEdges = [.leading, .trailing]) -> _ThrottleMachine<String> {
        _ThrottleMachine(interval: 100, edges: edges)
    }

    @Test func leadingAndTrailingRunsFirstThenLatestPerWindow() {
        var m = machine()
        #expect(m.send("a", now: 0) == true)
        #expect(m.next(now: 0) == .run("a"))
        _ = m.send("b", now: 10)
        _ = m.send("c", now: 20)
        #expect(m.next(now: 30) == .sleep(until: 100))
        #expect(m.next(now: 100) == .run("c"))
        _ = m.send("d", now: 150)
        #expect(m.next(now: 160) == .sleep(until: 200), "the window restarts at each start")
        #expect(m.next(now: 200) == .run("d"))
        #expect(m.next(now: 210) == .sleep(until: 300))
        #expect(m.next(now: 300) == .exit, "a window without values ends the worker")
    }

    @Test func leadingOnlyDropsValuesInsideTheWindow() {
        var m = machine(.leading)
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        _ = m.send("b", now: 50)
        #expect(m.next(now: 60) == .sleep(until: 100))
        #expect(m.next(now: 100) == .exit)
        #expect(m.send("c", now: 120) == true)
        #expect(m.next(now: 120) == .run("c"))
    }

    @Test func trailingOnlyRunsLatestAtWindowEnd() {
        var m = machine(.trailing)
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .sleep(until: 100))
        _ = m.send("b", now: 50)
        #expect(m.next(now: 100) == .run("b"))
        #expect(m.next(now: 110) == .exit)
        // the next value opens a new window
        _ = m.send("c", now: 130)
        #expect(m.next(now: 130) == .sleep(until: 230))
    }

    @Test func slowActionIsFollowedImmediatelyByTheLatestValue() {
        var m = machine()
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        _ = m.send("b", now: 10)
        _ = m.send("c", now: 20)
        // "a" took 250 ticks, longer than the interval
        #expect(m.next(now: 250) == .run("c"))
    }

    @Test func windowThatEndedBeforeTheWorkerWokeIsSettledBySend() {
        var m = machine()
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        #expect(m.next(now: 30) == .sleep(until: 100), "\"a\" returned; the worker sleeps")
        _ = m.send("b", now: 50)
        // the window ended at 100, the worker is late; "c" arrives at 130
        _ = m.send("c", now: 130)
        #expect(m.next(now: 135) == .run("b"))
        #expect(m.next(now: 140) == .sleep(until: 235))
        #expect(m.next(now: 235) == .run("c"))
    }

    @Test func leadingOnlyValueAfterAnUnsettledWindowRunsRightAway() {
        var m = machine(.leading)
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        // the window ended at 100 but the worker hasn't woken up yet
        _ = m.send("b", now: 130)
        #expect(m.next(now: 130) == .run("b"))
    }

    @Test func valuesSentAfterTheWindowWhileASlowActionRunsKeepOnlyTheLatest() {
        // "a" runs from 0 to 300, longer than the interval.
        var m = machine()
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        _ = m.send("b", now: 50)
        _ = m.send("c", now: 200) // the window ended, but the worker is busy, not late
        _ = m.send("d", now: 250)
        #expect(m.next(now: 300) == .run("d"), "the latest value runs as soon as the action returns")
        #expect(m.next(now: 310) == .sleep(until: 400))
        #expect(m.next(now: 400) == .exit)
    }

    @Test func leadingOnlyValueAfterTheWindowWaitsForASlowAction() {
        var m = machine(.leading)
        _ = m.send("a", now: 0)
        #expect(m.next(now: 0) == .run("a"))
        _ = m.send("b", now: 50)  // inside the window: dropped
        _ = m.send("c", now: 200) // after the window, while "a" still runs
        _ = m.send("d", now: 250)
        #expect(m.next(now: 300) == .run("d"))
    }

    @Test func resetDropsEverything() {
        var m = machine()
        _ = m.send("a", now: 0)
        m.reset()
        #expect(m.next(now: 0) == .exit)
        #expect(m.send("b", now: 10) == true)
        #expect(m.next(now: 10) == .run("b"))
    }
}
