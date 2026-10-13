@testable import Debounce
import Testing

/// Property tests: thousands of random scenarios run through the machines with a simulated worker
/// that behaves like the real one (sleep, run the action, ask again). Seeds are fixed, so failures
/// are reproducible.
@Suite struct MachineSimulationTests {
    static let interval: UInt64 = 100

    struct Run {
        let value: Int
        let start: UInt64
        let end: UInt64
        /// Returned by the first `next(now:)` after the previous action returned.
        let followsPrevious: Bool
    }

    /// Simulates the worker driving `machine` for the given sends and action durations.
    static func simulate<M: _PacingMachine>(
        _ machine: inout M,
        sends: [UInt64],
        duration: (Int) -> UInt64,
        startDelay: UInt64
    ) -> [Run] where M.Value == Int {
        var runs: [Run] = []
        var wake: UInt64? = nil // when the worker next asks the machine
        var sendIndex = 0
        var actionJustReturned = false
        while sendIndex < sends.count || wake != nil {
            let nextSend = sendIndex < sends.count ? sends[sendIndex] : .max
            if let w = wake, w <= nextSend {
                switch machine.next(now: w) {
                case .run(let value):
                    let end = w + duration(value)
                    runs.append(Run(value: value, start: w, end: end, followsPrevious: actionJustReturned))
                    actionJustReturned = true
                    // sends that arrive while the action runs
                    while sendIndex < sends.count, sends[sendIndex] < end {
                        _ = machine.send(sendIndex, now: sends[sendIndex])
                        sendIndex += 1
                    }
                    wake = end
                case .sleep(let until):
                    actionJustReturned = false
                    wake = max(until, w)
                    if until <= w { Issue.record("sleep into the past at \(w)") ; return runs }
                case .exit:
                    actionJustReturned = false
                    wake = nil
                }
            } else {
                if machine.send(sendIndex, now: nextSend) {
                    wake = nextSend + startDelay
                }
                sendIndex += 1
            }
        }
        return runs
    }

    static func randomSends(_ rng: inout SplitMix64, count: Int) -> [UInt64] {
        var t: UInt64 = 0
        return (0..<count).map { _ in
            // mostly quick bursts, sometimes pauses longer than the interval
            t += rng.next() % 4 == 0 ? rng.next() % 400 : rng.next() % 60
            return t
        }
    }

    static let edgeSets: [TriggerEdges] = [.leading, .trailing, [.leading, .trailing]]

    @Test(arguments: edgeSets)
    func debounceProperties(edges: TriggerEdges) {
        var rng = SplitMix64(seed: 42 &+ UInt64(edges.rawValue))
        for _ in 0..<2_000 {
            let sends = Self.randomSends(&rng, count: Int(rng.next() % 30) + 1)
            let maxDuration = rng.next() % 300 + 1
            let delay = rng.next() % 5
            var m = _DebounceMachine<Int>(interval: Self.interval, edges: edges)
            let runs = Self.simulate(&m, sends: sends, duration: { _ in rng.next() % maxDuration }, startDelay: delay)
            checkCommon(runs, sends: sends)
            if edges.contains(.trailing) {
                #expect(runs.last?.value == sends.count - 1, "the last value is always delivered")
            }
            if edges == .trailing {
                for run in runs {
                    let next = run.value + 1 < sends.count ? sends[run.value + 1] : .max
                    #expect(run.start >= sends[run.value] + Self.interval, "trailing waits the full quiet period")
                    #expect(next >= sends[run.value] + Self.interval || next > run.start,
                            "a value is only delivered once its burst is over")
                }
            }
            if edges == .leading {
                // A burst starts with a value sent at least one interval after the previous one.
                let burstStarts = sends.indices.filter { $0 == 0 || sends[$0] >= sends[$0 - 1] + Self.interval }
                #expect(runs.first?.value == 0, "the first value runs")
                #expect(runs.allSatisfy { burstStarts.contains($0.value) }, "only the first value of a burst runs")
                #expect(runs.last?.value == burstStarts.last, "the last burst always runs")
                for (previous, run) in zip([nil] + runs.map(Optional.some), runs) {
                    let free = max(sends[run.value] + delay, previous?.end ?? 0)
                    #expect(run.start <= free, "a burst's first value runs as soon as the worker is free")
                }
            }
            #expect(!m.isWorkerActive)
        }
    }

    @Test(arguments: edgeSets)
    func throttleProperties(edges: TriggerEdges) {
        var rng = SplitMix64(seed: 7 &+ UInt64(edges.rawValue))
        for _ in 0..<2_000 {
            let sends = Self.randomSends(&rng, count: Int(rng.next() % 40) + 1)
            let maxDuration = rng.next() % 300 + 1
            let delay = rng.next() % 5
            var m = _ThrottleMachine<Int>(interval: Self.interval, edges: edges)
            let runs = Self.simulate(&m, sends: sends, duration: { _ in rng.next() % maxDuration }, startDelay: delay)
            checkCommon(runs, sends: sends)
            for (a, b) in zip(runs, runs.dropFirst()) {
                #expect(b.start >= a.start + Self.interval, "starts are at least one interval apart")
            }
            checkFollowUpRunsGetTheLatestValue(runs, sends: sends)
            if edges.contains(.trailing) {
                #expect(runs.last?.value == sends.count - 1, "the last value is always delivered")
            }
            if edges == .leading, let last = runs.last {
                #expect(runs.first?.value == 0, "the first value runs")
                if sends[sends.count - 1] >= last.start + Self.interval {
                    #expect(last.value == sends.count - 1, "a value sent after the last interval ended runs")
                }
            }
            #expect(!m.isWorkerActive)
        }
    }

    /// Throttle: when an action starts right as the previous one returns, it gets the latest value
    /// sent so far, never an older one (rule R2). Debounce is different: a burst that ended during
    /// the action is due even if a newer burst has started, so this check doesn't apply there.
    func checkFollowUpRunsGetTheLatestValue(_ runs: [Run], sends: [UInt64]) {
        for (a, b) in zip(runs, runs.dropFirst()) where b.followsPrevious {
            // the machine has seen exactly the values sent while `a` ran
            let latest = sends.lastIndex { $0 < a.end }
            #expect(b.value == latest, "after a slow action the latest value runs, not an older one")
        }
    }

    /// Rules shared by both machines.
    func checkCommon(_ runs: [Run], sends: [UInt64]) {
        for (a, b) in zip(runs, runs.dropFirst()) {
            #expect(b.start >= a.end, "actions never overlap")
            #expect(b.value > a.value, "values are delivered in order, each at most once")
        }
        for run in runs {
            #expect(sends[run.value] <= run.start, "a value is never delivered before it was sent")
        }
    }
}

/// A small, fast, seedable random number generator.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
