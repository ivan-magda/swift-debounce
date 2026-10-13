import Debounce
import References
import Darwin
import Foundation
import Synchronization

// MARK: - Process metrics

struct ProcSnapshot {
    let wall: ContinuousClock.Instant
    let cpu: Double          // user + sys, seconds, all threads
    let ctxSwitches: Int     // voluntary + involuntary
    let footprint: Int       // phys_footprint, bytes

    static func now() -> ProcSnapshot {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)
            + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
        return ProcSnapshot(wall: .now, cpu: cpu,
                            ctxSwitches: ru.ru_nvcsw + ru.ru_nivcsw,
                            footprint: physFootprint())
    }
}

func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

extension Duration {
    var ms: Double { Double(components.seconds) * 1e3 + Double(components.attoseconds) / 1e15 }
    var ns: Double { Double(components.seconds) * 1e9 + Double(components.attoseconds) / 1e9 }
}

// MARK: - Implementations under test

enum Impl: String, CaseIterable {
    /// Cancel the previous Task and create a new one on every value.
    case simple
    /// One long-lived Task per burst and a state machine behind NSRecursiveLock.
    case longLivedTask = "long-lived Task"
    /// This package's `Debouncer`.
    case package = "swift-debounce"

    /// Runs `body` with the concrete type behind this case. Every `emit` is then statically
    /// dispatched and specialized; an existential (`any DebounceUnderTest<Int>`) would run the
    /// generic, unspecialized witness and add 70-200 ns to every call.
    func with<Body: WithDebouncer>(_ body: Body) async -> Body.Result {
        switch self {
        case .simple: await body { SimpleDebounce<Int>(dueTime: $0, output: $1) }
        case .longLivedTask: await body { LongLivedTaskDebounce<Int>(dueTime: $0, output: $1) }
        case .package: await body { Debouncer<Int>(for: $0, action: $1) }
        }
    }
}

typealias Maker<D> = (Duration, @escaping @Sendable (Int) async -> Void) -> D

protocol WithDebouncer {
    associatedtype Result
    func callAsFunction<D: DebounceUnderTest<Int>>(_ make: Maker<D>) async -> Result
}

/// The package isn't instrumented, so task counters only exist for the references.
let referenceOnlyMetrics: Set<String> = ["tasks", "wakeups"]

final class Sink: Sendable {
    let count = Atomic<Int>(0)
    let last = Atomic<Int>(-1)
    let lastAt = Mutex<ContinuousClock.Instant?>(nil)
    let stream: AsyncStream<Int>
    let cont: AsyncStream<Int>.Continuation

    init() { (stream, cont) = AsyncStream.makeStream(of: Int.self) }

    @Sendable func receive(_ v: Int) {
        lastAt.withLock { $0 = .now }
        count.add(1, ordering: .relaxed)
        last.store(v, ordering: .relaxed)
        cont.yield(v)
    }

    func waitFirst() async -> Int? {
        var it = stream.makeAsyncIterator()
        return await it.next()
    }
}

struct Run {
    var values: [String: Double] = [:]
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

/// Runs `body` `iterations` times for every implementation, interleaving them
/// (simple, long-lived Task, package, simple, ...) to cancel out thermal / background drift.
func compare(_ title: String, iterations: Int, warmup: Int = 2,
             metrics: [(key: String, label: String, fmt: String)],
             _ body: (Impl) async -> Run) async {
    print("\n## \(title)")
    for _ in 0..<warmup { for impl in Impl.allCases { _ = await body(impl) } }
    var all: [Impl: [Run]] = [:]
    for _ in 0..<iterations {
        for impl in Impl.allCases { all[impl, default: []].append(await body(impl)) }
    }
    print("| metric (median of \(iterations)) | simple | long-lived Task | swift-debounce |")
    print("|---|---:|---:|---:|")
    for m in metrics {
        let cells = Impl.allCases.map { impl -> String in
            if impl == .package && referenceOnlyMetrics.contains(m.key) { return "n/a" }
            return String(format: m.fmt, median(all[impl]!.map { $0.values[m.key] ?? .nan }))
        }
        print("| \(m.label) | " + cells.joined(separator: " | ") + " |")
    }
}

/// Lets in-flight (cancelled) tasks drain so their CPU cost is included.
func settle() async { try? await Task.sleep(for: .milliseconds(30)) }

// MARK: - Scenario 1: tight burst from a single thread

func burst(_ impl: Impl, n: Int) async -> Run { await impl.with(Burst(impl: impl, n: n)) }

struct Burst: WithDebouncer {
    let impl: Impl, n: Int
    func callAsFunction<D: DebounceUnderTest<Int>>(_ make: Maker<D>) async -> Run {
        let sink = Sink()
        let due = Duration.milliseconds(10)
        let d = make(due, sink.receive)
        DebounceMetrics.reset()

        let s0 = ProcSnapshot.now()
        for i in 0..<n { d.emit(value: i) }
        let s1 = ProcSnapshot.now()
        let v = await sink.waitFirst()
        let s2 = ProcSnapshot.now()
        await settle()
        let s3 = ProcSnapshot.now()
        withExtendedLifetime(d) {}
        precondition(v == n - 1 && sink.count.load(ordering: .relaxed) == 1, "\(impl) emitted wrong values")

        return Run(values: [
            "emitNs": (s1.wall - s0.wall).ns / Double(n),
            "emitMs": (s1.wall - s0.wall).ms,
            "toOutputMs": (s2.wall - s0.wall).ms,
            "cpuMs": (s3.cpu - s0.cpu) * 1e3,
            "csw": Double(s3.ctxSwitches - s0.ctxSwitches),
            "memKB": Double(max(0, s1.footprint - s0.footprint)) / 1024,
            "tasks": Double(DebounceMetrics.tasksCreated.load(ordering: .relaxed)),
            "wakeups": Double(DebounceMetrics.wakeups.load(ordering: .relaxed)),
        ])
    }
}

// MARK: - Scenario 2: many threads hammering one debouncer

func contention(_ impl: Impl, threads: Int, perThread: Int) async -> Run {
    await impl.with(Contention(threads: threads, perThread: perThread))
}

struct Contention: WithDebouncer {
    let threads: Int, perThread: Int
    func callAsFunction<D: DebounceUnderTest<Int>>(_ make: Maker<D>) async -> Run {
        let sink = Sink()
        let d = make(.milliseconds(20), sink.receive)
        DebounceMetrics.reset()

        let s0 = ProcSnapshot.now()
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread { d.emit(value: t * perThread + i) }
        }
        let s1 = ProcSnapshot.now()
        _ = await sink.waitFirst()
        await settle()
        let s2 = ProcSnapshot.now()
        withExtendedLifetime(d) {}

        let total = Double(threads * perThread)
        return Run(values: [
            "emitMs": (s1.wall - s0.wall).ms,
            "emitNs": (s1.wall - s0.wall).ns / total,
            "cpuMs": (s2.cpu - s0.cpu) * 1e3,
            "csw": Double(s2.ctxSwitches - s0.ctxSwitches),
            "tasks": Double(DebounceMetrics.tasksCreated.load(ordering: .relaxed)),
            "wakeups": Double(DebounceMetrics.wakeups.load(ordering: .relaxed)),
            "outputs": Double(sink.count.load(ordering: .relaxed)),
        ])
    }
}

// MARK: - Scenario 3: realistic "user typing" — events every `interval`, debounce `due`

/// `impl == nil` runs the same loop without a debouncer, to measure the harness itself.
func typing(_ impl: Impl?, events: Int, interval: Duration, due: Duration) async -> Run {
    await (impl ?? .simple).with(Typing(baseline: impl == nil, events: events, interval: interval, due: due))
}

struct Typing: WithDebouncer {
    let baseline: Bool, events: Int, interval: Duration, due: Duration
    func callAsFunction<D: DebounceUnderTest<Int>>(_ make: Maker<D>) async -> Run {
        let sink = Sink()
        let d: D? = baseline ? nil : make(due, sink.receive)
        DebounceMetrics.reset()

        let clock = ContinuousClock()
        let s0 = ProcSnapshot.now()
        let start = clock.now
        var lastEmit = start
        for i in 0..<events {
            try? await clock.sleep(until: start + interval * i)
            d?.emit(value: i)
            lastEmit = clock.now
        }
        if d != nil { _ = await sink.waitFirst() } else { try? await clock.sleep(for: due) }
        await settle()
        let s1 = ProcSnapshot.now()
        withExtendedLifetime(d) {}

        let fired = sink.lastAt.withLock { $0 }
        return Run(values: [
            "cpuMs": (s1.cpu - s0.cpu) * 1e3,
            "csw": Double(s1.ctxSwitches - s0.ctxSwitches),
            "tasks": Double(DebounceMetrics.tasksCreated.load(ordering: .relaxed)),
            "wakeups": Double(DebounceMetrics.wakeups.load(ordering: .relaxed)),
            "outputs": Double(sink.count.load(ordering: .relaxed)),
            "lateMs": fired.map { ($0 - lastEmit - due).ms } ?? .nan,
        ])
    }
}

// MARK: - Scenario 4: many independent debouncers (e.g. one per list cell)

func fanOut(_ impl: Impl, instances: Int, emitsEach: Int) async -> Run {
    await impl.with(FanOut(instances: instances, emitsEach: emitsEach))
}

struct FanOut: WithDebouncer {
    let instances: Int, emitsEach: Int
    func callAsFunction<D: DebounceUnderTest<Int>>(_ make: Maker<D>) async -> Run {
        let sink = Sink()
        let ds = (0..<instances).map { _ in make(.milliseconds(50), sink.receive) }
        DebounceMetrics.reset()

        let s0 = ProcSnapshot.now()
        for round in 0..<emitsEach { for d in ds { d.emit(value: round) } }
        let s1 = ProcSnapshot.now()
        while sink.count.load(ordering: .relaxed) < instances { try? await Task.sleep(for: .milliseconds(5)) }
        await settle()
        let s2 = ProcSnapshot.now()
        withExtendedLifetime(ds) {}

        return Run(values: [
            "emitMs": (s1.wall - s0.wall).ms,
            "cpuMs": (s2.cpu - s0.cpu) * 1e3,
            "memKB": Double(max(0, s1.footprint - s0.footprint)) / 1024,
            "tasks": Double(DebounceMetrics.tasksCreated.load(ordering: .relaxed)),
            "wakeups": Double(DebounceMetrics.wakeups.load(ordering: .relaxed)),
            "csw": Double(s2.ctxSwitches - s0.ctxSwitches),
        ])
    }
}

struct Latency: WithDebouncer {
    func callAsFunction<D: DebounceUnderTest<Int>>(_ make: Maker<D>) async -> [Double] {
        var lates: [Double] = []
        for _ in 0..<40 {
            let sink = Sink()
            let d = make(.milliseconds(30), sink.receive)
            for i in 0..<20 { d.emit(value: i) }
            let last = ContinuousClock.now
            _ = await sink.waitFirst()
            withExtendedLifetime(d) {}
            lates.append((sink.lastAt.withLock { $0! } - last - .milliseconds(30)).ms)
        }
        return lates
    }
}

// MARK: - Main

#if DEBUG
print("⚠️  Run with `swift run -c release Scenarios`: debug numbers are meaningless.")
#endif
setvbuf(stdout, nil, _IOLBF, 0)
print("# Scenarios: a new Task per value (simple) vs one long-lived Task per burst vs swift-debounce")
print("CPU: \(ProcessInfo.processInfo.activeProcessorCount) cores, \(ProcessInfo.processInfo.operatingSystemVersionString)")

/// `Scenarios latency` runs only the timing scenarios (3 and 5).
let onlyLatency = CommandLine.arguments.dropFirst().first == "latency"

if !onlyLatency {
for n in [1_000, 10_000, 100_000] {
    await compare("1. Burst: \(n) emits in a tight loop (1 thread, debounce 10 ms)", iterations: 15, metrics: [
        ("emitNs", "emit() cost, ns/call", "%.0f"),
        ("emitMs", "emit loop wall time, ms", "%.2f"),
        ("toOutputMs", "first emit → output, ms", "%.2f"),
        ("cpuMs", "total CPU (all threads), ms", "%.2f"),
        ("memKB", "footprint growth during loop, KB", "%.0f"),
        ("csw", "context switches", "%.0f"),
        ("tasks", "Tasks created", "%.0f"),
        ("wakeups", "task wake-ups", "%.0f"),
    ]) { await burst($0, n: n) }
}

await compare("2. Contention: 8 threads × 25 000 emits into one debouncer", iterations: 10, metrics: [
    ("emitNs", "wall time per emit, ns", "%.0f"),
    ("emitMs", "emit phase wall time, ms", "%.1f"),
    ("cpuMs", "total CPU, ms", "%.1f"),
    ("csw", "context switches", "%.0f"),
    ("tasks", "Tasks created", "%.0f"),
    ("wakeups", "task wake-ups", "%.0f"),
    ("outputs", "outputs delivered", "%.0f"),
]) { await contention($0, threads: 8, perThread: 25_000) }
}

// Baseline: the same timed loop with no debouncer, to subtract the harness's own CPU.
var baseline: [Double] = []
for _ in 0..<5 { baseline.append(await typing(nil, events: 200, interval: .milliseconds(5), due: .milliseconds(50)).values["cpuMs"]!) }
print("\n(typing baseline without any debouncer: \(String(format: "%.2f", median(baseline))) ms CPU)")

await compare("3. Typing: 200 events every 5 ms, debounce 50 ms (~1 s of real time)", iterations: 7, warmup: 1, metrics: [
    ("cpuMs", "total CPU incl. baseline, ms", "%.2f"),
    ("csw", "context switches", "%.0f"),
    ("tasks", "Tasks created", "%.0f"),
    ("wakeups", "task wake-ups", "%.0f"),
    ("outputs", "outputs delivered", "%.0f"),
    ("lateMs", "output delay beyond 50 ms, ms", "%.2f"),
]) { await typing($0, events: 200, interval: .milliseconds(5), due: .milliseconds(50)) }

if !onlyLatency {
await compare("4. Fan-out: 10 000 debouncers × 10 emits each", iterations: 7, metrics: [
    ("emitMs", "emit phase wall time, ms", "%.1f"),
    ("cpuMs", "total CPU, ms", "%.1f"),
    ("memKB", "footprint growth during emits, KB", "%.0f"),
    ("csw", "context switches", "%.0f"),
    ("tasks", "Tasks created", "%.0f"),
    ("wakeups", "task wake-ups", "%.0f"),
]) { await fanOut($0, instances: 10_000, emitsEach: 10) }
}

// Latency precision on a short burst
print("\n## 5. Latency: 20 rapid emits, delay from last emit to output beyond 30 ms debounce (40 reps)")
print("| | p50, ms | p95, ms | max, ms |")
print("|---|---:|---:|---:|")
for impl in Impl.allCases {
    let lates = await impl.with(Latency())
    print("| \(impl.rawValue) | \(String(format: "%.2f", median(lates))) | \(String(format: "%.2f", percentile(lates, 0.95))) | \(String(format: "%.2f", lates.max()!)) |")
}
