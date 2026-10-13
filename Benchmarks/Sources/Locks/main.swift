import Debounce
import References
import Darwin
import Foundation
import Synchronization

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Helpers

func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
}

func ctxSwitches() -> Int {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return ru.ru_nvcsw + ru.ru_nivcsw
}

extension Duration {
    var ns: Double { Double(components.seconds) * 1e9 + Double(components.attoseconds) / 1e9 }
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// ns per iteration, median of `runs`.
@inline(never)
func nsPerOp(runs: Int = 7, iterations: Int, _ body: (Int) -> Void) -> Double {
    body(iterations / 10) // warm-up
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        body(iterations)
        samples.append((ContinuousClock.now - start).ns / Double(iterations))
    }
    return median(samples)
}

func row(_ cells: String...) { print("| " + cells.joined(separator: " | ") + " |") }
func f(_ x: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", x) }

final class Sink: Sendable {
    let count = Atomic<Int>(0)
    let stream: AsyncStream<Int>
    let cont: AsyncStream<Int>.Continuation
    init() { (stream, cont) = AsyncStream.makeStream(of: Int.self) }
    @Sendable func receive(_ v: Int) { count.add(1, ordering: .relaxed); cont.yield(v) }
    func waitFirst() async -> Int? { var it = stream.makeAsyncIterator(); return await it.next() }
}

// MARK: - Profile mode: `swift run -c release Locks profile <seconds> [package|existential]` — spin send/emit for `sample`

if CommandLine.arguments.dropFirst().first == "profile" {
    let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "5") ?? 5
    let viaExistential = CommandLine.arguments.contains("existential")
    let fast = CommandLine.arguments.contains("package")
    let subject = fast ? "swift-debounce Debouncer.send" : "long-lived Task reference emit (\(viaExistential ? "existential" : "concrete"))"
    print("pid \(getpid()), profiling \(subject) for \(seconds)s")
    let concrete = LongLivedTaskDebounce<Int>(dueTime: .seconds(3600)) { _ in }
    let fastD = Debouncer<Int>(for: .seconds(3600)) { _ in }
    let existential: any DebounceUnderTest<Int> = concrete
    let deadline = ContinuousClock.now + .seconds(seconds)
    var i = 0
    while ContinuousClock.now < deadline {
        for _ in 0..<10_000 {
            if fast { fastD.send(i) } else if viaExistential { existential.emit(value: i) } else { concrete.emit(value: i) }
            i &+= 1
        }
    }
    print("emits: \(i)")
    exit(0)
}

#if DEBUG
print("⚠️  Run in release.")
#endif
print("# Lock & emit() profiling — \(ProcessInfo.processInfo.environment["CMO"] == "1" ? "CMO on" : "default build")")

// MARK: - 1. Building blocks of emit()

print("\n## 1. Building blocks of emit(), single thread, ns/op")
row("operation", "ns/op"); row("---", "---:")

row("ContinuousClock.now", f(nsPerOp(iterations: 5_000_000) { n in
    for _ in 0..<n { blackHole(ContinuousClock.now) }
}))
row("SuspendingClock.now", f(nsPerOp(iterations: 5_000_000) { n in
    for _ in 0..<n { blackHole(SuspendingClock.now) }
}))
row("mach_continuous_time()", f(nsPerOp(iterations: 5_000_000) { n in
    var acc: UInt64 = 0; for _ in 0..<n { acc &+= mach_continuous_time() }; blackHole(acc)
}))
row("clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)", f(nsPerOp(iterations: 5_000_000) { n in
    var acc: UInt64 = 0; for _ in 0..<n { acc &+= clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }; blackHole(acc)
}))
row("mach_absolute_time()", f(nsPerOp(iterations: 5_000_000) { n in
    var acc: UInt64 = 0; for _ in 0..<n { acc &+= mach_absolute_time() }; blackHole(acc)
}))

@inline(never) func blackHole<T>(_ x: T) { _ = x }


// MARK: - 2. Raw locks

final class Counter<L: RawLock>: @unchecked Sendable {
    let lock = L()
    var value = 0
}

@inline(never)
func uncontended<L: RawLock>(_: L.Type) -> Double {
    let c = Counter<L>()
    return nsPerOp(iterations: 2_000_000) { n in for _ in 0..<n { c.lock.withLock { c.value &+= 1 } } }
}

@inline(never)
func contended<L: RawLock>(_: L.Type, threads: Int = 8, perThread: Int = 200_000) -> Double {
    var samples: [Double] = []
    for _ in 0..<5 {
        let c = Counter<L>()
        let start = ContinuousClock.now
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<perThread { c.lock.withLock { c.value &+= 1 } }
        }
        samples.append((ContinuousClock.now - start).ns / Double(threads * perThread))
        precondition(c.value == threads * perThread)
    }
    return median(samples)
}

struct LockCase {
    let name: String
    let uncontended: () -> Double
    let contended: () -> Double
}

func lockCase<L: RawLock>(_ name: String, _ t: L.Type) -> LockCase {
    LockCase(name: name, uncontended: { uncontended(t) }, contended: { contended(t) })
}

let locks: [LockCase] = [
    lockCase("NSRecursiveLock (long-lived Task reference)", RecursiveLockImpl.self),
    lockCase("NSLock", NSLockImpl.self),
    lockCase("pthread_mutex_t", PthreadMutexImpl.self),
    lockCase("os_unfair_lock (heap-allocated)", UnfairLockImpl.self),
    lockCase("OSAllocatedUnfairLock", OSAllocatedUnfairLockImpl.self),
    lockCase("Synchronization.Mutex", MutexImpl.self),
    lockCase("DispatchQueue.sync (serial)", SerialQueueImpl.self),
    lockCase("DispatchSemaphore", SemaphoreImpl.self),
]

print("\n## 2. Raw locks: withLock { counter += 1 }, ns per op (wall)")
row("lock", "1 thread", "8 threads contended"); row("---", "---:", "---:")
for l in locks { row(l.name, f(l.uncontended()), f(l.contended())) }

// Actor equivalent of the counter. Global funcs are nonisolated; top-level code is @MainActor.
actor ActorCounter { var value = 0; func inc() { value &+= 1 } }

func actorCounterNonisolated() async -> (Double, Double) {
    var s1: [Double] = [], s8: [Double] = []
    for _ in 0..<5 {
        let a = ActorCounter()
        var start = ContinuousClock.now
        for _ in 0..<200_000 { await a.inc() }
        s1.append((ContinuousClock.now - start).ns / 200_000)
        start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 { g.addTask { for _ in 0..<50_000 { await a.inc() } } }
        }
        s8.append((ContinuousClock.now - start).ns / 400_000)
    }
    return (median(s1), median(s8))
}

do {
    let (one, eight) = await actorCounterNonisolated()
    row("actor, `await` from nonisolated task", f(one), f(eight))
    let a = ActorCounter()
    let start = ContinuousClock.now
    for _ in 0..<20_000 { await a.inc() }
    row("actor, `await` from @MainActor", f((ContinuousClock.now - start).ns / 20_000), "—")
}

// MARK: - 3. Full emit() with each variant

/// Single-thread burst. Returns ns per emit. `D` is concrete → the call is statically dispatched.
@inline(never)
func burstConcrete<D: DebounceUnderTest<Int>>(_ make: (@escaping @Sendable (Int) async -> Void) -> D, n: Int = 1_000_000) async -> Double {
    var samples: [Double] = []
    for run in 0..<6 {
        let sink = Sink()
        let d = make(sink.receive)
        let start = ContinuousClock.now
        for i in 0..<n { d.emit(value: i) }
        let elapsed = (ContinuousClock.now - start).ns / Double(n)
        let v = await sink.waitFirst()
        withExtendedLifetime(d) {}
        precondition(v == n - 1)
        if run > 0 { samples.append(elapsed) }
    }
    return median(samples)
}

/// Same, but through `any DebounceUnderTest<Int>` as in the first benchmark.
@inline(never)
func burstExistential(_ make: (@escaping @Sendable (Int) async -> Void) -> any DebounceUnderTest<Int>, n: Int = 1_000_000) async -> Double {
    var samples: [Double] = []
    for run in 0..<6 {
        let sink = Sink()
        let d = make(sink.receive)
        let start = ContinuousClock.now
        for i in 0..<n { d.emit(value: i) }
        let elapsed = (ContinuousClock.now - start).ns / Double(n)
        let v = await sink.waitFirst()
        withExtendedLifetime(d) {}
        precondition(v == n - 1)
        if run > 0 { samples.append(elapsed) }
    }
    return median(samples)
}

struct ContentionResult { var nsPerEmit: Double; var cpuNsPerEmit: Double; var csw: Double }

@inline(never)
func contention<D: DebounceUnderTest<Int>>(_ make: (@escaping @Sendable (Int) async -> Void) -> D,
                                   threads: Int = 8, perThread: Int = 100_000) async -> ContentionResult {
    var wall: [Double] = [], cpu: [Double] = [], csw: [Double] = []
    for run in 0..<6 {
        let sink = Sink()
        let d = make(sink.receive)
        let c0 = cpuSeconds(), s0 = ctxSwitches(), start = ContinuousClock.now
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread { d.emit(value: t * perThread + i) }
        }
        let total = Double(threads * perThread)
        let w = (ContinuousClock.now - start).ns / total
        let cp = (cpuSeconds() - c0) * 1e9 / total
        let cs = Double(ctxSwitches() - s0)
        _ = await sink.waitFirst()
        withExtendedLifetime(d) {}
        if run > 0 { wall.append(w); cpu.append(cp); csw.append(cs) }
    }
    return ContentionResult(nsPerEmit: median(wall), cpuNsPerEmit: median(cpu), csw: median(csw))
}

let due = Duration.milliseconds(20)

print("\n## 3. Long-lived Task reference: how is emit() called?")
row("call style", "ns/emit"); row("---", "---:")
row("`any DebounceUnderTest<Int>` (first benchmark)", f(await burstExistential { LongLivedTaskDebounce(dueTime: due, output: $0) }))
row("concrete `LongLivedTaskDebounce<Int>`", f(await burstConcrete { LongLivedTaskDebounce(dueTime: due, output: $0) }))

print("\n## 4. Same algorithm, different lock — 1 thread × 1M emits and 8 threads × 100k emits")
row("variant", "1 thread, ns/emit", "8 threads, wall ns/emit", "8 threads, CPU ns/emit", "ctx switches")
row("---", "---:", "---:", "---:", "---:")

func report<D: DebounceUnderTest<Int>>(_ name: String, _ make: @escaping (@escaping @Sendable (Int) async -> Void) -> D) async {
    let single = await burstConcrete(make)
    let multi = await contention(make)
    row(name, f(single), f(multi.nsPerEmit), f(multi.cpuNsPerEmit), f(multi.csw, 0))
}

await report("SafeStorage + NSRecursiveLock (long-lived Task reference)") { LongLivedTaskDebounce<Int>(dueTime: due, output: $0) }
await report("NSRecursiveLock") { LockedDebounce<Int, RecursiveLockImpl>(dueTime: due, output: $0) }
await report("NSLock") { LockedDebounce<Int, NSLockImpl>(dueTime: due, output: $0) }
await report("pthread_mutex_t") { LockedDebounce<Int, PthreadMutexImpl>(dueTime: due, output: $0) }
await report("os_unfair_lock") { LockedDebounce<Int, UnfairLockImpl>(dueTime: due, output: $0) }
await report("OSAllocatedUnfairLock") { LockedDebounce<Int, OSAllocatedUnfairLockImpl>(dueTime: due, output: $0) }
await report("Mutex (as a plain lock)") { LockedDebounce<Int, MutexImpl>(dueTime: due, output: $0) }
await report("DispatchQueue.sync") { LockedDebounce<Int, SerialQueueImpl>(dueTime: due, output: $0) }
await report("DispatchSemaphore") { LockedDebounce<Int, SemaphoreImpl>(dueTime: due, output: $0) }
await report("Mutex<State>, one critical section") { MutexDebounce<Int>(dueTime: due, output: $0) }
await report("**swift-debounce `Debouncer`**") { Debouncer<Int>(for: due, action: $0) }

// Actor: emit must be awaited
func actorEmitBench() async -> (Double, Double, Double, Double) {
    var single: [Double] = [], multi: [Double] = [], cpu: [Double] = [], csw: [Double] = []
    for run in 0..<6 {
        var sink = Sink()
        var d = ActorDebounce<Int>(dueTime: due, output: sink.receive)
        var start = ContinuousClock.now
        for i in 0..<1_000_000 { await d.emit(value: i) }
        let s = (ContinuousClock.now - start).ns / 1_000_000
        let last = await sink.waitFirst()
        precondition(last == 999_999)

        sink = Sink()
        d = ActorDebounce<Int>(dueTime: due, output: sink.receive)
        let c0 = cpuSeconds(), s0 = ctxSwitches()
        start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { [d] g in
            for t in 0..<8 { g.addTask { for i in 0..<100_000 { await d.emit(value: t * 100_000 + i) } } }
        }
        let m = (ContinuousClock.now - start).ns / 800_000
        let cp = (cpuSeconds() - c0) * 1e9 / 800_000
        let cs = Double(ctxSwitches() - s0)
        _ = await sink.waitFirst()
        if run > 0 { single.append(s); multi.append(m); cpu.append(cp); csw.append(cs) }
    }
    return (median(single), median(multi), median(cpu), median(csw))
}

do {
    let (single, multi, cpu, csw) = await actorEmitBench()
    row("actor (`await emit` from nonisolated task)", f(single), f(multi), f(cpu), f(csw, 0))
    let sink = Sink()
    let d = ActorDebounce<Int>(dueTime: due, output: sink.receive)
    let start = ContinuousClock.now
    for i in 0..<20_000 { await d.emit(value: i) }
    let fromMain = (ContinuousClock.now - start).ns / 20_000
    _ = await sink.waitFirst()
    row("actor (`await emit` from @MainActor)", f(fromMain), "—", "—", "—")
}
