import Debounce
import Foundation
import Testing

/// End-to-end tests through the public API only, in real time.
extension TimingTests {
    @Suite struct DebouncerE2ETests {
        // MARK: Typical use

        @MainActor
        @Test func searchFieldSearchesOnceWhenTypingStops() async {
            var searches: [String] = []
            var searchedOnMain = true
            // Created inside a @MainActor function: the closure inherits the main actor, so it can
            // touch main-actor state without annotations.
            let search = Debouncer(for: 0.3) { (query: String) in
                searchedOnMain = checkMainActor()
                searches.append(query)
            }
            // The whole burst in one main-actor turn. Awaiting between sends let a busy CI runner
            // resume this test more than 1 s late and split the burst; other tests cover the timing.
            for prefix in ["S", "Sw", "Swi", "Swif", "Swift"] {
                search.send(prefix)
            }
            #expect(await eventually { searches == ["Swift"] })
            await sleep(milliseconds: 500)
            #expect(searches == ["Swift"], "no extra searches")
            #expect(searchedOnMain)
        }

        @Test func leadingEdgeRunsTheFirstTapRightAwayAndDropsTheRest() async {
            let taps = Recorder<UInt64>()
            let pay = Debouncer(for: 1, edges: .leading) { (tap: Int) in taps.append(UInt64(tap)) }
            for tap in 1...5 { pay.send(tap) }
            #expect(await eventually(timeout: 800) { taps.values == [1] }, "the first tap runs before the burst is over")
            await sleep(milliseconds: 1_300)
            #expect(taps.values == [1])
            pay.send(6) // a new burst
            #expect(await eventually { taps.values == [1, 6] })
        }

        @Test func bothEdgesRunFirstAndLastValues() async {
            let values = Recorder<String>()
            let debouncer = Debouncer(for: 0.05, edges: [.leading, .trailing]) { (value: String) in values.append(value) }
            debouncer.send("a")
            debouncer.send("b")
            debouncer.send("c")
            #expect(await eventually { values.values == ["a", "c"] })
        }

        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
        @Test func durationInitializerWorks() async {
            let values = Recorder<Int>()
            let debouncer = Debouncer(for: .milliseconds(30)) { (value: Int) in values.append(value) }
            debouncer.send(1)
            debouncer.send(2)
            #expect(await eventually { values.values == [2] })
        }

        @Test func voidDebouncerSendsSignals() async {
            let count = Recorder<Void>()
            let reload = Debouncer(for: 0.03) { count.append(()) }
            reload.send()
            reload.send()
            #expect(await eventually { count.values.count == 1 })
        }

        @Test func nonisolatedActionRunsOffTheMainThread() async {
            let threads = Recorder<Bool>()
            let debouncer = Debouncer(for: 0.02) { (_: Int) in threads.append(onMainThread()) }
            debouncer.send(1)
            #expect(await eventually { threads.values == [false] })
        }

        // MARK: Cancellation and lifetime

        @Test func cancelDropsThePendingValueAndTheDebouncerKeepsWorking() async {
            let values = Recorder<Int>()
            let debouncer = Debouncer(for: 0.05) { (value: Int) in values.append(value) }
            debouncer.send(1)
            debouncer.cancel()
            await sleep(milliseconds: 150)
            #expect(values.values.isEmpty)
            debouncer.send(2)
            #expect(await eventually { values.values == [2] })
        }

        @Test func releasingTheDebouncerDropsThePendingValue() async {
            let values = Recorder<Int>()
            do {
                let debouncer = Debouncer(for: 0.05) { (value: Int) in values.append(value) }
                debouncer.send(1)
            }
            await sleep(milliseconds: 150)
            #expect(values.values.isEmpty)
        }

        @Test func cancelReachesTheRunningAction() async throws {
            let started = Recorder<Int>()
            let outcomes = Recorder<Bool>()
            let debouncer = Debouncer(for: 0.01) { (value: Int) in
                started.append(value)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                outcomes.append(Task.isCancelled)
            }
            debouncer.send(1)
            try #require(await eventually { started.values == [1] })
            debouncer.cancel()
            // Without the cancel the action would sleep for 5 s.
            #expect(await eventually(timeout: 2_000) { outcomes.values == [true] })
        }

        /// Rule R4: a cancel on the action's actor wins even if the worker was already on its way.
        @MainActor
        @Test func cancelOnTheMainActorStopsAnActionThatWasAboutToStart() async {
            var didRun = false
            let debouncer = Debouncer(for: 0.02) { (_: Int) in didRun = true }
            debouncer.send(1)
            // Block the main thread past the deadline: the worker wakes up, takes the value and waits
            // to hop onto the main actor.
            usleep(150_000)
            debouncer.cancel()
            await sleep(milliseconds: 100)
            #expect(!didRun)
        }

        // MARK: Serial execution

        @Test func actionsNeverOverlap() async {
            let probe = ConcurrencyProbe()
            let values = Recorder<Int>()
            let debouncer = Debouncer(for: 0.01) { (value: Int) in
                probe.enter()
                await sleep(milliseconds: 60)
                values.append(value)
                probe.leave()
            }
            for value in 1...6 {
                debouncer.send(value)
                await sleep(milliseconds: 25) // each value outlives the quiet period
            }
            #expect(await eventually { values.values.last == 6 })
            #expect(probe.peak == 1)
            #expect(values.values == values.values.sorted(), "values arrive in order")
        }

        /// Rule R1 across `cancel()`: the next action waits for the cancelled one to return.
        @Test func nextActionWaitsForACancelledActionThatIsStillRunning() async throws {
            let events = Recorder<String>()
            let gate = Gate()
            let debouncer = Debouncer(for: 0.01) { (value: Int) in
                events.append("start \(value)")
                if value == 1 { await gate.wait() } // ignores cancellation
                events.append("end \(value)")
            }
            debouncer.send(1)
            try #require(await eventually { events.values == ["start 1"] })
            debouncer.cancel()
            debouncer.send(2)
            await sleep(milliseconds: 100)
            #expect(events.values == ["start 1"], "2 must not start while 1 is still running")
            gate.open()
            #expect(await eventually { events.values == ["start 1", "end 1", "start 2", "end 2"] })
        }

        @Test func manyThreadsSendingAtOnceProduceOneAction() async {
            let values = Recorder<Int>()
            // A long quiet period: on a CPU-starved CI runner the senders can stall for tens of
            // milliseconds, which would legitimately split the burst in two.
            let debouncer = Debouncer(for: 1) { (value: Int) in values.append(value) }
            DispatchQueue.concurrentPerform(iterations: 8) { thread in
                for i in 0..<10_000 { debouncer.send(thread * 10_000 + i) }
            }
            #expect(await eventually(timeout: 4_000) { values.values.count == 1 })
            await sleep(milliseconds: 300)
            #expect(values.values.count == 1)
        }
    }
}
