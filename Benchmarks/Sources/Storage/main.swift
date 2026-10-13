import Debounce
import References
import Darwin
import Foundation
import Synchronization

setvbuf(stdout, nil, _IOLBF, 0)

func cpu() -> Double {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
}
func csw() -> Int { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return ru.ru_nvcsw + ru.ru_nivcsw }
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
func p(_ x: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", x) }
extension Duration { var ns: Double { Double(components.seconds) * 1e9 + Double(components.attoseconds) / 1e9 } }
func heapInUse() -> Int { var s = malloc_statistics_t(); malloc_zone_statistics(nil, &s); return Int(s.size_in_use) }

final class Sink: Sendable {
    let stream: AsyncStream<Int>; let cont: AsyncStream<Int>.Continuation
    init() { (stream, cont) = AsyncStream.makeStream(of: Int.self) }
    @Sendable func receive(_ v: Int) { cont.yield(v) }
    func first() async -> Int? { var it = stream.makeAsyncIterator(); return await it.next() }
}

struct Variant {
    let name: String
    let rawSingle: () -> Double
    let rawMulti: () -> Double
    let sendSingle: () async -> Double
    let sendMulti: () async -> (wall: Double, cpu: Double, csw: Double)
    let bytesPerInstance: () -> Double
}

@inline(never)
func makeVariant<B: LockedBox<Int>, DB: LockedBox<BoxState<Int>>>(_ name: String, _: B.Type, _: DB.Type) -> Variant {
    Variant(
        name: name,
        rawSingle: {
            let b = B(0); let n = 5_000_000
            let t = ContinuousClock.now
            for _ in 0..<n { b.withLock { $0 &+= 1 } }
            return (ContinuousClock.now - t).ns / Double(n)
        },
        rawMulti: {
            let b = B(0); let per = 250_000
            let t = ContinuousClock.now
            DispatchQueue.concurrentPerform(iterations: 8) { _ in for _ in 0..<per { b.withLock { $0 &+= 1 } } }
            let r = (ContinuousClock.now - t).ns / Double(8 * per)
            precondition(b.withLock { $0 } == 8 * per)
            return r
        },
        sendSingle: {
            let sink = Sink()
            let d = BoxedDebounce<Int, DB>(dueTime: .milliseconds(20), output: sink.receive)
            let n = 2_000_000
            let t = ContinuousClock.now
            for i in 0..<n { d.emit(value: i) }
            let r = (ContinuousClock.now - t).ns / Double(n)
            let last = await sink.first()
            withExtendedLifetime(d) {}
            precondition(last == n - 1)
            return r
        },
        sendMulti: {
            let sink = Sink()
            let d = BoxedDebounce<Int, DB>(dueTime: .milliseconds(20), output: sink.receive)
            let per = 100_000
            let c0 = cpu(), s0 = csw(), t = ContinuousClock.now
            DispatchQueue.concurrentPerform(iterations: 8) { k in for i in 0..<per { d.emit(value: k * per + i) } }
            let total = Double(8 * per)
            let r = ((ContinuousClock.now - t).ns / total, (cpu() - c0) * 1e9 / total, Double(csw() - s0))
            _ = await sink.first()
            withExtendedLifetime(d) {}
            return r
        },
        bytesPerInstance: {
            let n = 100_000
            let before = heapInUse()
            var keep: [BoxedDebounce<Int, DB>] = []
            keep.reserveCapacity(n)
            let afterReserve = heapInUse()
            for _ in 0..<n { keep.append(BoxedDebounce<Int, DB>(dueTime: .milliseconds(20)) { _ in }) }
            let r = Double(heapInUse() - afterReserve) / Double(n)
            withExtendedLifetime(keep) {}
            _ = before
            return r
        }
    )
}

let variants: [Variant] = [
    makeVariant("Synchronization.Mutex (iOS 18+)", MutexBox<Int>.self, MutexBox<BoxState<Int>>.self),
    makeVariant("ManagedBuffer + os_unfair_lock (iOS 13+)", ManagedUnfairBox<Int>.self, ManagedUnfairBox<BoxState<Int>>.self),
    makeVariant("ManagedBuffer + os_unfair_lock, lock padded 128 B (iOS 13+)", PaddedManagedUnfairBox<Int>.self, PaddedManagedUnfairBox<BoxState<Int>>.self),
    makeVariant("OSAllocatedUnfairLock (iOS 16+)", AllocatedUnfairBox<Int>.self, AllocatedUnfairBox<BoxState<Int>>.self),
    makeVariant("os_unfair_lock, separate heap alloc (iOS 13+)", HeapUnfairBox<Int>.self, HeapUnfairBox<BoxState<Int>>.self),
]

let rounds = 9
var raw1 = [[Double]](repeating: [], count: variants.count), raw8 = raw1, s1 = raw1, s8w = raw1, s8c = raw1, s8s = raw1, mem = raw1
// warm-up
for v in variants { _ = v.rawSingle(); _ = await v.sendSingle() }
for round in 0..<rounds {
    // rotate the order every round so no variant always runs first/last
    for k in 0..<variants.count {
        let i = (k + round) % variants.count
        let v = variants[i]
        raw1[i].append(v.rawSingle())
        raw8[i].append(v.rawMulti())
        s1[i].append(await v.sendSingle())
        let m = await v.sendMulti()
        s8w[i].append(m.wall); s8c[i].append(m.cpu); s8s[i].append(m.csw)
        mem[i].append(v.bytesPerInstance())
    }
}

print("# Lock storage for the package — median of \(rounds) interleaved rounds")
print("| storage | lock, 1 thread ns | lock, 8 threads ns | send, 1 thread ns | send, 8 threads wall ns | send, 8 threads CPU ns | ctx switches | heap bytes / debouncer |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for (i, v) in variants.enumerated() {
    print("| \(v.name) | \(p(median(raw1[i]))) | \(p(median(raw8[i]))) | \(p(median(s1[i]))) | \(p(median(s8w[i]))) | \(p(median(s8c[i]))) | \(p(median(s8s[i]), 0)) | \(p(median(mem[i]), 0)) |")
}
print("\nmin–max across rounds:")
for (i, v) in variants.enumerated() {
    print("- \(v.name): send 1 thread \(p(s1[i].min()!))–\(p(s1[i].max()!)) ns; send 8 threads wall \(p(s8w[i].min()!))–\(p(s8w[i].max()!)) ns, CPU \(p(s8c[i].min()!))–\(p(s8c[i].max()!)) ns")
}
