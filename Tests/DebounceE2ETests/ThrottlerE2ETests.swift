import Debounce
import Foundation
import Testing

/// End-to-end tests through the public API only, in real time.
extension TimingTests {
    @Suite struct ThrottlerE2ETests {
        struct Start: Sendable { let value: Int; let time: UInt64 }

        @Test func steadyStreamRunsAtMostOncePerInterval() async {
            let starts = Recorder<Start>()
            let throttler = Throttler(for: 0.1) { (value: Int) in starts.append(Start(value: value, time: now())) }
            let begin = now()
            var value = 0
            while now() - begin < 550_000_000 {
                value += 1
                throttler.send(value)
                await sleep(milliseconds: 5)
            }
            let last = value
            #expect(await eventually { starts.values.last?.value == last }, "the latest value is delivered")
            let recorded = starts.values
            #expect(recorded.first?.value == 1, "the first value runs right away")
            let elapsed = Double(now() - begin) / 1e9
            #expect(recorded.count >= 2 && Double(recorded.count) <= elapsed / 0.1 + 2,
                    "about one start per 100 ms, got \(recorded.count) in \(elapsed) s")
            for (a, b) in zip(recorded, recorded.dropFirst()) {
                // Measured inside the action, after the hop to its executor, so scheduling jitter
                // can shrink a gap a little. The machine tests check the exact spacing.
                #expect(b.time - a.time >= 70_000_000)
            }
        }

        @Test func leadingOnlyDropsValuesInsideTheInterval() async {
            let values = Recorder<Int>()
            let throttler = Throttler(for: 0.1, edges: .leading) { (value: Int) in values.append(value) }
            throttler.send(1)
            throttler.send(2)
            throttler.send(3)
            await sleep(milliseconds: 200)
            #expect(values.values == [1])
            throttler.send(4)
            #expect(await eventually { values.values == [1, 4] })
        }

        @Test func trailingOnlyRunsTheLatestValueAtTheEndOfTheInterval() async {
            let values = Recorder<Int>()
            let throttler = Throttler(for: 0.5, edges: .trailing) { (value: Int) in values.append(value) }
            throttler.send(1)
            throttler.send(2)
            await sleep(milliseconds: 100)
            #expect(values.values.isEmpty, "nothing runs on the leading edge")
            #expect(await eventually { values.values == [2] })
        }

        @Test func slowActionsNeverOverlap() async {
            let probe = ConcurrencyProbe()
            let values = Recorder<Int>()
            let throttler = Throttler(for: 0.01) { (value: Int) in
                probe.enter()
                await sleep(milliseconds: 50)
                values.append(value)
                probe.leave()
            }
            for value in 1...20 {
                throttler.send(value)
                await sleep(milliseconds: 5)
            }
            #expect(await eventually { values.values.last == 20 })
            #expect(probe.peak == 1)
        }

        @Test func slowActionIsFollowedByTheLatestValueOnly() async {
            let values = Recorder<Int>()
            let started = Recorder<Int>()
            let gate = Gate()
            let throttler = Throttler(for: 0.1) { (value: Int) in
                started.append(value)
                if value == 0 { await gate.wait() } // 0 runs until the test opens the gate
                values.append(value)
            }
            throttler.send(0)
            #expect(await eventually { started.values == [0] })
            throttler.send(1)
            await sleep(milliseconds: 200) // the interval is over, but 0 is still running
            throttler.send(2)
            throttler.send(3)
            gate.open()
            #expect(await eventually { values.values.count == 2 })
            await sleep(milliseconds: 300)
            #expect(values.values == [0, 3])
        }

        @Test func cancelDropsThePendingValue() async {
            let values = Recorder<Int>()
            let throttler = Throttler(for: 0.5) { (value: Int) in values.append(value) }
            throttler.send(1) // runs right away
            throttler.send(2) // pending for the trailing edge
            #expect(await eventually { values.values == [1] })
            throttler.cancel()
            await sleep(milliseconds: 700)
            #expect(values.values == [1])
        }

        @MainActor
        @Test func mainActorActionRunsOnTheMainThread() async {
            var threads: [Bool] = []
            let throttler = Throttler(for: 0.02) { (_: Int) in threads.append(checkMainActor()) }
            throttler.send(1)
            #expect(await eventually { threads == [true] })
        }

        @Test func voidThrottlerSendsSignals() async {
            let count = Recorder<Void>()
            let refresh = Throttler(for: 0.05) { count.append(()) }
            refresh.send()
            refresh.send()
            refresh.send()
            #expect(await eventually { count.values.count == 2 }, "leading + trailing")
        }
    }
}
