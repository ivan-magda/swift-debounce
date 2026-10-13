import Debounce
import Dispatch
import References
import Synchronization

// How late does the action run after the quiet period ends? Measured with nothing else running,
// from a plain task, for each implementation and send pattern. (The Scenarios benchmark measures
// latency too, but there its timed loop runs on the main actor and adds noise of its own.)

setvbuf(stdout, nil, _IOLBF, 0)

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func median(_ x: [Double]) -> Double { let s = x.sorted(); return s[s.count / 2] }
func percentile(_ x: [Double], _ p: Double) -> Double { let s = x.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
func f(_ x: Double) -> String { String(format: "%.2f", x) }

final class FireTime: Sendable {
    let value = Atomic<UInt64>(0)
    @Sendable func record(_: Int) { value.store(now(), ordering: .relaxed) }
}

/// Milliseconds past `dueTime` at which the action ran, for one burst.
func lateness<D: DebounceUnderTest<Int>>(
    _ make: (Duration, @escaping @Sendable (Int) async -> Void) -> D,
    sends: Int, cadenceMs: UInt64?
) async -> Double {
    let fired = FireTime()
    let debouncer = make(.milliseconds(50), fired.record)
    var lastSend: UInt64 = 0
    for i in 0..<sends {
        if let cadenceMs { try? await Task.sleep(nanoseconds: cadenceMs * 1_000_000) }
        debouncer.emit(value: i)
        lastSend = now()
    }
    while fired.value.load(ordering: .relaxed) == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    withExtendedLifetime(debouncer) {}
    return Double(fired.value.load(ordering: .relaxed) - lastSend) / 1e6 - 50
}

func lateness(_ impl: Int, sends: Int, cadenceMs: UInt64?) async -> Double {
    switch impl {
    case 0: await lateness({ SimpleDebounce<Int>(dueTime: $0, output: $1) }, sends: sends, cadenceMs: cadenceMs)
    case 1: await lateness({ LongLivedTaskDebounce<Int>(dueTime: $0, output: $1) }, sends: sends, cadenceMs: cadenceMs)
    default: await lateness({ Debouncer<Int>(for: $0, action: $1) }, sends: sends, cadenceMs: cadenceMs)
    }
}

let implementations = ["simple", "long-lived Task", "swift-debounce"]

let patterns: [(String, Int, UInt64?)] = [
    ("1 value", 1, nil),
    ("20 values at once", 20, nil),
    ("60 values, one every 5 ms", 60, 5),
]

print("# Latency: how late the action runs after a 50 ms quiet period (30 bursts each, interleaved)")
print("| pattern | implementation | median, ms | p95, ms |")
print("|---|---|---:|---:|")
await Task.detached {
    for (name, sends, cadence) in patterns {
        var late = [[Double]](repeating: [], count: implementations.count)
        for round in 0..<30 {
            // rotate the order every round so no implementation always goes first
            for k in implementations.indices {
                let impl = (k + round) % implementations.count
                late[impl].append(await lateness(impl, sends: sends, cadenceMs: cadence))
            }
        }
        for (impl, values) in zip(implementations, late) {
            print("| \(name) | \(impl) | \(f(median(values))) | \(f(percentile(values, 0.95))) |")
        }
    }
}.value
