import Foundation
import Testing

extension Tag {
    /// Tests that depend on real time. They use wide margins and run one at a time.
    @Tag static var timing: Self
}

/// Parent of every suite that depends on real time. `.serialized` only orders the tests inside one
/// suite hierarchy, so all timing suites live under this one to run strictly one at a time.
@Suite(.serialized, .tags(.timing))
enum TimingTests {}

/// Thread-safe list of recorded events.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        storage.append(element)
    }

    var values: [Element] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Counts how many actions run at the same time.
final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximum = 0

    func enter() { lock.lock(); current += 1; maximum = max(maximum, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return maximum }
}

/// A gate an action can wait on. Ignores cancellation on purpose, to model work that
/// doesn't stop when cancelled.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

func sleep(milliseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

/// Polls `condition` until it's true or the timeout passes. Runs on the caller's actor.
func eventually(
    timeout milliseconds: UInt64 = 2_000,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return true }
        await sleep(milliseconds: 5)
    }
    return condition()
}

func onMainThread() -> Bool { Thread.isMainThread }

/// Traps unless the caller runs on the main actor, then reports whether that's the main thread.
///
/// The executor check is what matters for isolation. The thread check only holds on Apple
/// platforms: on Linux the test runner's main actor doesn't run on the main thread.
func checkMainActor() -> Bool {
    if #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) {
        MainActor.preconditionIsolated()
    }
    #if canImport(Darwin)
    return Thread.isMainThread
    #else
    return true
    #endif
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
