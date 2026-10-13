import Foundation
import os
import Synchronization

/// Minimal lock abstraction so the same debouncer can be benchmarked with every primitive.
public protocol RawLock: Sendable {
    init()
    func withLock<R>(_ body: () -> R) -> R
}

public final class RecursiveLockImpl: RawLock {
    private let lock = NSRecursiveLock()
    public init() {}
    public func withLock<R>(_ body: () -> R) -> R { lock.lock(); defer { lock.unlock() }; return body() }
}

public final class NSLockImpl: RawLock {
    private let lock = NSLock()
    public init() {}
    public func withLock<R>(_ body: () -> R) -> R { lock.lock(); defer { lock.unlock() }; return body() }
}

public final class PthreadMutexImpl: RawLock, @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    public init() {
        mutex = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
    }
    deinit { pthread_mutex_destroy(mutex); mutex.deallocate() }
    public func withLock<R>(_ body: () -> R) -> R { pthread_mutex_lock(mutex); defer { pthread_mutex_unlock(mutex) }; return body() }
}

/// Raw os_unfair_lock. It MUST live at a stable address: `var lock = os_unfair_lock()` +
/// `os_unfair_lock_lock(&lock)` is undefined behaviour in Swift (inout may pass a temporary copy).
public final class UnfairLockImpl: RawLock, @unchecked Sendable {
    private let lock: os_unfair_lock_t
    public init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }
    public func withLock<R>(_ body: () -> R) -> R { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return body() }
}

/// Apple's safe wrapper over os_unfair_lock (iOS 16+ / macOS 13+).
public struct OSAllocatedUnfairLockImpl: RawLock {
    private let lock = OSAllocatedUnfairLock()
    public init() {}
    public func withLock<R>(_ body: () -> R) -> R { lock.withLockUnchecked(body) }
}

/// Swift's Synchronization.Mutex (iOS 18+ / macOS 15+). Boxed in a class only to fit
/// the protocol; `MutexDebounce` below shows the idiomatic usage (state stored inside the Mutex).
public final class MutexImpl: RawLock {
    private let mutex = Mutex(())
    public init() {}
    public func withLock<R>(_ body: () -> R) -> R {
        mutex.withLock { _ in body() }
    }
}

public final class SerialQueueImpl: RawLock {
    private let queue = DispatchQueue(label: "bench.serial")
    public init() {}
    public func withLock<R>(_ body: () -> R) -> R { queue.sync(execute: body) }
}

public final class SemaphoreImpl: RawLock {
    private let semaphore = DispatchSemaphore(value: 1)
    public init() {}
    public func withLock<R>(_ body: () -> R) -> R { semaphore.wait(); defer { semaphore.signal() }; return body() }
}

// MARK: - The long-lived-Task debouncer, generic over the lock

final class LockedStorage<T, L: RawLock>: @unchecked Sendable {
    private let lock = L()
    private var stored: T
    init(_ stored: T) { self.stored = stored }
    func apply<R>(_ block: (inout T) -> R) -> R { lock.withLock { block(&stored) } }
}

/// Same algorithm and the same two-storage layout as `LongLivedTaskDebounce`; only the lock varies.
public final class LockedDebounce<T: Sendable, L: RawLock>: DebounceUnderTest {
    private let output: @Sendable (T) async -> Void
    private let stateMachine: LockedStorage<DebounceStateMachine<T>, L>
    private let task = LockedStorage<Task<Void, Never>?, L>(nil)

    public init(dueTime: Duration, output: @Sendable @escaping (T) async -> Void) {
        self.stateMachine = LockedStorage(DebounceStateMachine(duration: dueTime))
        self.output = output
    }

    public func emit(value: T) {
        let (shouldStartATask, dueTime) = stateMachine.apply { $0.newValue(value) }
        guard shouldStartATask else { return }

        DebounceMetrics.tasksCreated.add(1, ordering: .relaxed)
        let newTask = Task { [stateMachine, output] in
            var localDueTime = dueTime
            loop: while true {
                try? await Task.sleep(until: localDueTime, clock: .continuous)
                DebounceMetrics.wakeups.add(1, ordering: .relaxed)
                switch stateMachine.apply({ $0.sleepIsOver() }) {
                case .finishDebouncing(let value):
                    await output(value)
                    break loop
                case .continueDebouncing(let newDueTime):
                    localDueTime = newDueTime
                }
            }
        }
        task.apply { $0 = newTask }
    }

    deinit { task.apply { $0 }?.cancel() }
}

// MARK: - Idiomatic Mutex: one critical section for state machine + task handle

public final class MutexDebounce<T: Sendable>: DebounceUnderTest {
    struct State {
        var machine: DebounceStateMachine<T>
        var task: Task<Void, Never>?
    }

    final class Core: Sendable {
        let state: Mutex<State>
        let output: @Sendable (T) async -> Void
        init(dueTime: Duration, output: @Sendable @escaping (T) async -> Void) {
            self.state = Mutex(State(machine: DebounceStateMachine(duration: dueTime), task: nil))
            self.output = output
        }
    }

    private let core: Core

    public init(dueTime: Duration, output: @Sendable @escaping (T) async -> Void) {
        core = Core(dueTime: dueTime, output: output)
    }

    public func emit(value: T) {
        let core = self.core
        core.state.withLock { state in
            let (shouldStartATask, dueTime) = state.machine.newValue(value)
            guard shouldStartATask else { return }
            DebounceMetrics.tasksCreated.add(1, ordering: .relaxed)
            // Created under the lock (once per burst), so the stored handle always
            // belongs to the current burst — no race between two `task.set` calls.
            state.task = Task {
                var localDueTime = dueTime
                while true {
                    try? await Task.sleep(until: localDueTime, clock: .continuous)
                    DebounceMetrics.wakeups.add(1, ordering: .relaxed)
                    let finished: T? = core.state.withLock { state in
                        switch state.machine.sleepIsOver() {
                        case .finishDebouncing(let value): return value
                        case .continueDebouncing(let newDueTime): localDueTime = newDueTime; return nil
                        }
                    }
                    if let finished {
                        await core.output(finished)
                        return
                    }
                }
            }
        }
    }

    deinit { core.state.withLock { $0.task }?.cancel() }
}

// MARK: - Actor: no lock at all, but `emit` becomes async

public actor ActorDebounce<T: Sendable> {
    private var machine: DebounceStateMachine<T>
    private var task: Task<Void, Never>?
    private let output: @Sendable (T) async -> Void

    public init(dueTime: Duration, output: @Sendable @escaping (T) async -> Void) {
        machine = DebounceStateMachine(duration: dueTime)
        self.output = output
    }

    public func emit(value: T) {
        let (shouldStartATask, dueTime) = machine.newValue(value)
        guard shouldStartATask else { return }
        DebounceMetrics.tasksCreated.add(1, ordering: .relaxed)
        task = Task { await self.run(dueTime: dueTime) }
    }

    private func run(dueTime: ContinuousClock.Instant) async {
        var localDueTime = dueTime
        while true {
            try? await Task.sleep(until: localDueTime, clock: .continuous)
            DebounceMetrics.wakeups.add(1, ordering: .relaxed)
            switch machine.sleepIsOver() {
            case .finishDebouncing(let value):
                await output(value)
                return
            case .continueDebouncing(let newDueTime):
                localDueTime = newDueTime
            }
        }
    }

    deinit { task?.cancel() }
}
