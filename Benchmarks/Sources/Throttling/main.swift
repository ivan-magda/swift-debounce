import Darwin
import Debounce
import Dispatch
import Synchronization

setvbuf(stdout, nil, _IOLBF, 0)

func cpuSeconds() -> Double {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
}
func contextSwitches() -> Int { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return ru.ru_nvcsw + ru.ru_nivcsw }
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
func percentile(_ xs: [Double], _ p: Double) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
func f(_ x: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", x) }
extension Duration { var ns: Double { Double(components.seconds) * 1e9 + Double(components.attoseconds) / 1e9 } }

final class Starts: Sendable {
    let times = Mutex<[ContinuousClock.Instant]>([])
    let last = Atomic<Int>(-1)
    @Sendable func record(_ value: Int) {
        times.withLock { $0.append(.now) }
        last.store(value, ordering: .relaxed)
    }
}

func waitForLast(_ starts: Starts, _ value: Int) async {
    while starts.last.load(ordering: .relaxed) != value { try? await Task.sleep(for: .milliseconds(1)) }
}

print("# Throttler — interval 20 ms unless noted, medians of 7 runs")

// 1. Cost of send from one thread
do {
    var throttle: [Double] = [], debounce: [Double] = []
    for run in 0..<8 {
        let n = 2_000_000
        let starts = Starts()
        let t = Throttler<Int>(for: .milliseconds(20), action: starts.record)
        var begin = ContinuousClock.now
        for i in 0..<n { t.send(i) }
        let tns = (ContinuousClock.now - begin).ns / Double(n)
        await waitForLast(starts, n - 1)

        let d = Debouncer<Int>(for: .milliseconds(20), action: starts.record)
        begin = ContinuousClock.now
        for i in 0..<n { d.send(i) }
        let dns = (ContinuousClock.now - begin).ns / Double(n)
        await waitForLast(starts, n - 1)
        if run > 0 { throttle.append(tns); debounce.append(dns) }
        withExtendedLifetime((t, d)) {}
    }
    print("\n## 1. `send` from one thread, 2M values")
    print("| type | ns per send |")
    print("|---|---:|")
    print("| Throttler (leading + trailing) | \(f(median(throttle))) |")
    print("| Debouncer (trailing), for comparison | \(f(median(debounce))) |")
}

// 2. Eight threads sending at once
do {
    var wall: [Double] = [], cpu: [Double] = [], csw: [Double] = []
    for run in 0..<8 {
        let starts = Starts()
        let t = Throttler<Int>(for: .milliseconds(20), action: starts.record)
        let perThread = 100_000
        let c0 = cpuSeconds(), s0 = contextSwitches(), begin = ContinuousClock.now
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for i in 0..<perThread { t.send(thread * perThread + i) }
        }
        let total = Double(8 * perThread)
        if run > 0 {
            wall.append((ContinuousClock.now - begin).ns / total)
            cpu.append((cpuSeconds() - c0) * 1e9 / total)
            csw.append(Double(contextSwitches() - s0))
        }
        try? await Task.sleep(for: .milliseconds(50))
        withExtendedLifetime(t) {}
    }
    print("\n## 2. 8 threads × 100k sends into one throttler")
    print("| wall ns per send | CPU ns per send | context switches |")
    print("|---:|---:|---:|")
    print("| \(f(median(wall))) | \(f(median(cpu))) | \(f(median(csw), 0)) |")
}

// 3. Pace under a steady stream
do {
    let interval = 50.0
    var counts: [Double] = [], gapMedian: [Double] = [], gapMin: [Double] = [], gapP95: [Double] = [], cpuPerSecond: [Double] = []
    for _ in 0..<5 {
        let starts = Starts()
        let t = Throttler<Int>(for: .milliseconds(Int(interval)), action: starts.record)
        let c0 = cpuSeconds()
        let begin = ContinuousClock.now
        var i = 0
        while ContinuousClock.now - begin < .seconds(2) {
            t.send(i); i += 1
            try? await Task.sleep(for: .milliseconds(1))
        }
        await waitForLast(starts, i - 1)
        let elapsed = (ContinuousClock.now - begin).ns / 1e9
        cpuPerSecond.append((cpuSeconds() - c0) * 1e3 / elapsed)
        let times = starts.times.withLock { $0 }
        let gaps = zip(times, times.dropFirst()).map { ($1 - $0).ns / 1e6 }
        counts.append(Double(times.count))
        gapMedian.append(median(gaps)); gapMin.append(gaps.min()!); gapP95.append(percentile(gaps, 0.95))
        withExtendedLifetime(t) {}
    }
    print("\n## 3. Steady stream: a value every ~1 ms for 2 s, interval \(Int(interval)) ms")
    print("| starts | gap median, ms | gap min, ms | gap p95, ms | CPU ms per second (incl. the sending loop) |")
    print("|---:|---:|---:|---:|---:|")
    print("| \(f(median(counts), 0)) | \(f(median(gapMedian), 2)) | \(f(median(gapMin), 2)) | \(f(median(gapP95), 2)) | \(f(median(cpuPerSecond), 2)) |")
}
