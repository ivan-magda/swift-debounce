@testable import Debounce
import Foundation
import Testing

@Suite(.serialized) struct EngineTests {
    final class Payload: Sendable {}

    @Test func coreAndPendingValueAreReleasedAfterDeinit() async {
        weak var weakCore: _PacerCore<_DebounceMachine<Payload>>?
        weak var weakPayload: Payload?
        do {
            let debouncer = Debouncer(for: 10) { (_: Payload) in }
            let payload = Payload()
            weakPayload = payload
            weakCore = debouncer.core
            debouncer.send(payload) // pending for 10 s
        }
        // deinit cancelled the sleeping worker; it lets go of the core shortly after
        let released = await waitFor { weakCore == nil && weakPayload == nil }
        #expect(released)
    }

    @Test func idleDebouncerHoldsNoWorker() async {
        let debouncer = Debouncer(for: 0.01) { (_: Int) in }
        debouncer.send(1)
        let idle = await waitFor { debouncer.storage.withLock { $0.worker == nil && !$0.machine.isWorkerActive } }
        #expect(idle)
    }

    @Test func throttlerIsReleasedWhileItsWorkerSleeps() async {
        weak var weakCore: _PacerCore<_ThrottleMachine<Int>>?
        do {
            let throttler = Throttler(for: 10) { (_: Int) in }
            weakCore = throttler.core
            throttler.send(1)
            throttler.send(2)
        }
        #expect(await waitFor { weakCore == nil })
    }

    @Test func lockDoesNotShareACacheLineWithTheState() {
        let storage = _LockedStorage<(Int, Int, Int, Int)>.create((1, 2, 3, 4))
        let distance = storage.withUnsafeMutablePointers { state, elements in
            UInt(bitPattern: elements + _LockedStorage<(Int, Int, Int, Int)>.lockIndex)
                - UInt(bitPattern: state + 1)
        }
        #expect(distance >= 128, "the lock starts at least 128 bytes after the end of the state")
    }

    @Test func timebaseRoundTripsAndClamps() {
        let timebase = _Timebase.current
        let ticks = timebase.ticks(fromNanoseconds: 1_000_000)
        let back = timebase.nanoseconds(fromTicks: ticks)
        #expect(back >= 1_000_000 && back < 1_001_000)
        #expect(timebase.ticks(fromNanoseconds: 0.1) == 1, "never zero")
        #expect(timebase.ticks(fromNanoseconds: .greatestFiniteMagnitude) < .max, "huge intervals are clamped")
    }

    @Test func clockIsMonotonic() {
        var previous = _MonotonicClock.now()
        for _ in 0..<10_000 {
            let current = _MonotonicClock.now()
            #expect(current >= previous)
            previous = current
        }
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}
