import Darwin
import os
import Synchronization

// SPIKE: which lock+state storage should the package use on all Darwin versions?
// The same algorithm (the package's, simplified) is instantiated with each storage.

public protocol LockedBox<Wrapped>: AnyObject, Sendable {
    associatedtype Wrapped
    init(_ initial: sending Wrapped)
    func withLock<R>(_ body: (inout Wrapped) -> R) -> R
}

/// Synchronization.Mutex stored inline (iOS 18+). Reference.
public final class MutexBox<Wrapped>: LockedBox, @unchecked Sendable {
    @usableFromInline let mutex: Mutex<Wrapped>
    @inlinable public init(_ initial: sending Wrapped) { mutex = Mutex(initial) }
    @inlinable public func withLock<R>(_ body: (inout Wrapped) -> R) -> R {
        nonisolated(unsafe) let body = body
        return mutex._unsafeWithLock(body)
    }
}

extension Mutex {
    @inlinable func _unsafeWithLock<R>(_ body: (inout Value) -> R) -> R {
        withLock { (v: inout sending Value) -> sending R in
            nonisolated(unsafe) let r = body(&v)
            return r
        }
    }
}

/// Candidate: ManagedBuffer with the state as header and os_unfair_lock as the single element.
/// One allocation, stable lock address, works on iOS 13+ (this is how OSAllocatedUnfairLock is built).
public final class ManagedUnfairBox<Wrapped>: LockedBox, @unchecked Sendable {
    @usableFromInline final class Storage: ManagedBuffer<Wrapped, os_unfair_lock_s> {
        deinit { _ = withUnsafeMutablePointerToElements { $0.deinitialize(count: 1) } }
    }
    @usableFromInline let storage: Storage
    @inlinable public init(_ initial: sending Wrapped) {
        let buffer = Storage.create(minimumCapacity: 1) { buf in
            buf.withUnsafeMutablePointerToElements { $0.initialize(to: os_unfair_lock_s()) }
            return initial
        }
        storage = unsafeDowncast(buffer, to: Storage.self)
    }
    @inlinable public func withLock<R>(_ body: (inout Wrapped) -> R) -> R {
        storage.withUnsafeMutablePointers { state, lock in
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return body(&state.pointee)
        }
    }
}

/// Same as ManagedUnfairBox, but the lock lives 128 bytes (one Apple Silicon cache line) after
/// the element base, so lock word and state never share a cache line.
public final class PaddedManagedUnfairBox<Wrapped>: LockedBox, @unchecked Sendable {
    @usableFromInline static var lockIndex: Int { 128 / MemoryLayout<os_unfair_lock_s>.stride }
    @usableFromInline final class Storage: ManagedBuffer<Wrapped, os_unfair_lock_s> {
        deinit { _ = withUnsafeMutablePointerToElements { ($0 + PaddedManagedUnfairBox.lockIndex).deinitialize(count: 1) } }
    }
    @usableFromInline let storage: Storage
    @inlinable public init(_ initial: sending Wrapped) {
        let buffer = Storage.create(minimumCapacity: Self.lockIndex + 1) { buf in
            buf.withUnsafeMutablePointerToElements { ($0 + Self.lockIndex).initialize(to: os_unfair_lock_s()) }
            return initial
        }
        storage = unsafeDowncast(buffer, to: Storage.self)
    }
    @inlinable public func withLock<R>(_ body: (inout Wrapped) -> R) -> R {
        storage.withUnsafeMutablePointers { state, base in
            let lock = base + Self.lockIndex
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return body(&state.pointee)
        }
    }
}

/// OSAllocatedUnfairLock<State> (iOS 16+).
public final class AllocatedUnfairBox<Wrapped>: LockedBox, @unchecked Sendable {
    @usableFromInline let lock: OSAllocatedUnfairLock<Wrapped>
    @inlinable public init(_ initial: sending Wrapped) {
        nonisolated(unsafe) let initial = initial
        lock = OSAllocatedUnfairLock(uncheckedState: initial)
    }
    @inlinable public func withLock<R>(_ body: (inout Wrapped) -> R) -> R { lock.withLockUnchecked(body) }
}

/// os_unfair_lock in its own heap allocation + state stored next to the pointer (two allocations).
public final class HeapUnfairBox<Wrapped>: LockedBox, @unchecked Sendable {
    @usableFromInline let lock: os_unfair_lock_t
    @usableFromInline var state: Wrapped
    @inlinable public init(_ initial: sending Wrapped) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        state = initial
    }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }
    @inlinable public func withLock<R>(_ body: (inout Wrapped) -> R) -> R {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return body(&state)
    }
}

// MARK: - A debouncer generic over the storage

public struct BoxState<T> {
    @usableFromInline var value: T?
    @usableFromInline var deadline: UInt64 = 0
    @usableFromInline var isValueDuringSleep = false
    @usableFromInline var task: Task<Void, Never>?
    @inlinable public init() {}
}

public final class BoxedDebounce<T: Sendable, Box: LockedBox<BoxState<T>>>: DebounceUnderTest {
    @usableFromInline let box: Box
    @usableFromInline let durationTicks: UInt64
    @usableFromInline let numer: UInt64, denom: UInt64
    @usableFromInline let output: @Sendable (T) async -> Void

    @inlinable public init(dueTime: Duration, output: @Sendable @escaping (T) async -> Void) {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer); denom = UInt64(tb.denom)
        let ns = UInt64(dueTime.components.seconds) * 1_000_000_000 + UInt64(dueTime.components.attoseconds / 1_000_000_000)
        durationTicks = ns * denom / numer
        box = Box(BoxState())
        self.output = output
    }

    @inlinable public func emit(value: T) {
        let deadline = mach_continuous_time() &+ durationTicks
        box.withLock { s in
            s.value = value
            s.deadline = max(s.deadline, deadline)
            if s.task == nil {
                s.task = Task { [box, numer, denom, output] in
                    await Self.run(box: box, until: deadline, numer: numer, denom: denom, output: output)
                }
            } else {
                s.isValueDuringSleep = true
            }
        }
    }

    @usableFromInline static func run(box: Box, until first: UInt64, numer: UInt64, denom: UInt64,
                                      output: @Sendable (T) async -> Void) async {
        var deadline = first
        while true {
            let now = mach_continuous_time()
            if deadline > now {
                do { try await Task.sleep(nanoseconds: (deadline - now) * numer / denom) } catch { return }
            }
            let finished: T? = box.withLock { s in
                if s.isValueDuringSleep { s.isValueDuringSleep = false; deadline = s.deadline; return nil }
                let v = s.value; s = BoxState(); return v
            }
            if let finished { await output(finished); return }
        }
    }

    deinit { box.withLock { $0.task }?.cancel() }
}
