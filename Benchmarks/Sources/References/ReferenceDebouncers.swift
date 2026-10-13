import Foundation
import Synchronization

// Two common ways to write a debouncer, used as references:
// - SimpleDebounce cancels the previous Task and creates a new one on every value.
// - LongLivedTaskDebounce keeps one Task per burst and a state machine, guarded by NSRecursiveLock.
// Both use the same lock so the comparison measures the approach, not the primitive.

/// Counters used by the benchmark. A relaxed atomic increment costs a few ns,
/// negligible next to creating a Task (~µs), and is applied to both variants equally.
public enum DebounceMetrics {
    public static let tasksCreated = Atomic<Int>(0)
    /// Number of times a debounce task woke up from `Task.sleep` (normally or via cancellation).
    public static let wakeups = Atomic<Int>(0)

    public static func reset() {
        tasksCreated.store(0, ordering: .relaxed)
        wakeups.store(0, ordering: .relaxed)
    }
}

public protocol DebounceUnderTest<Value>: Sendable {
    associatedtype Value: Sendable
    func emit(value: Value)
}

final class SafeStorage<T>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var stored: T

    init(stored: T) { self.stored = stored }

    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(stored: T) {
        lock.lock(); defer { lock.unlock() }
        self.stored = stored
    }

    func apply<R>(block: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return block(&stored)
    }
}

// MARK: - 1. Simple: cancel previous Task, create a new one on every emit

public final class SimpleDebounce<T: Sendable>: DebounceUnderTest {
    private let output: @Sendable (T) async -> Void
    private let dueTime: Duration
    private let task = SafeStorage<Task<Void, Never>?>(stored: nil)

    public init(dueTime: Duration, output: @Sendable @escaping (T) async -> Void) {
        self.dueTime = dueTime
        self.output = output
    }

    public func emit(value: T) {
        let output = self.output
        let dueTime = self.dueTime
        task.apply { task in
            task?.cancel()
            DebounceMetrics.tasksCreated.add(1, ordering: .relaxed)
            task = Task {
                do {
                    try await Task.sleep(for: dueTime)
                    DebounceMetrics.wakeups.add(1, ordering: .relaxed)
                    await output(value)
                } catch {
                    DebounceMetrics.wakeups.add(1, ordering: .relaxed)
                }
            }
        }
    }

    deinit { task.get()?.cancel() }
}

// MARK: - 2. Optimized: one long-lived Task per burst + state machine

struct DebounceStateMachine<T> {
    enum State {
        case idle
        case debouncing(value: T, dueTime: ContinuousClock.Instant, isValueDuringSleep: Bool)
    }

    enum SleepIsOverAction {
        case continueDebouncing(dueTime: ContinuousClock.Instant)
        case finishDebouncing(value: T)
    }

    private var state: State = .idle
    private let duration: Duration

    init(duration: Duration) { self.duration = duration }

    /// Returns `true` when a new debouncing task must be started.
    mutating func newValue(_ value: T) -> (Bool, ContinuousClock.Instant) {
        let dueTime = ContinuousClock.now + duration
        switch state {
        case .idle:
            state = .debouncing(value: value, dueTime: dueTime, isValueDuringSleep: false)
            return (true, dueTime)
        case .debouncing:
            state = .debouncing(value: value, dueTime: dueTime, isValueDuringSleep: true)
            return (false, dueTime)
        }
    }

    mutating func sleepIsOver() -> SleepIsOverAction {
        switch state {
        case .idle:
            fatalError("inconsistent state, no value was being debounced.")
        case .debouncing(let value, let dueTime, true):
            state = .debouncing(value: value, dueTime: dueTime, isValueDuringSleep: false)
            return .continueDebouncing(dueTime: dueTime)
        case .debouncing(let value, _, false):
            state = .idle
            return .finishDebouncing(value: value)
        }
    }
}

public final class LongLivedTaskDebounce<T: Sendable>: DebounceUnderTest {
    private let output: @Sendable (T) async -> Void
    private let stateMachine: SafeStorage<DebounceStateMachine<T>>
    private let task = SafeStorage<Task<Void, Never>?>(stored: nil)

    public init(dueTime: Duration, output: @Sendable @escaping (T) async -> Void) {
        self.stateMachine = SafeStorage(stored: DebounceStateMachine(duration: dueTime))
        self.output = output
    }

    public func emit(value: T) {
        let (shouldStartATask, dueTime) = stateMachine.apply { $0.newValue(value) }
        guard shouldStartATask else { return }

        DebounceMetrics.tasksCreated.add(1, ordering: .relaxed)
        task.set(stored: Task { [stateMachine, output] in
            var localDueTime = dueTime
            loop: while true {
                try? await Task.sleep(until: localDueTime, clock: .continuous)
                DebounceMetrics.wakeups.add(1, ordering: .relaxed)

                switch stateMachine.apply(block: { $0.sleepIsOver() }) {
                case .finishDebouncing(let value):
                    await output(value)
                    break loop
                case .continueDebouncing(let newDueTime):
                    localDueTime = newDueTime
                }
            }
        })
    }

    deinit { task.get()?.cancel() }
}
