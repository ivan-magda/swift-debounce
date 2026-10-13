#if canImport(os)
import os
@usableFromInline typealias _PlatformLock = os_unfair_lock_s
#elseif canImport(Glibc)
import Glibc
@usableFromInline typealias _PlatformLock = pthread_mutex_t
#elseif canImport(Musl)
import Musl
@usableFromInline typealias _PlatformLock = pthread_mutex_t
#endif

/// State protected by a lock, kept in a single heap allocation.
///
/// The state is the buffer header and the lock lives in the element area, so the lock has a stable
/// address on every OS version the package supports. On Apple platforms the lock is an
/// `os_unfair_lock`: `Synchronization.Mutex` compiles down to the same calls there, but it requires
/// iOS 18. Elsewhere it's a `pthread_mutex_t`.
///
/// The lock sits at least 128 bytes after the start of the element area, so it never shares a cache
/// line with the state (Apple silicon uses 128-byte lines). Under contention this made `send` about
/// 1.5 times faster and much more stable. See `Benchmarks/README.md`.
///
/// `ManagedBuffer` can't be `Sendable`, so owners store it as `nonisolated(unsafe)`: every access
/// to the state goes through ``withLock(_:)``.
@usableFromInline
final class _LockedStorage<State>: ManagedBuffer<State, _PlatformLock> {
    @inlinable @inline(__always)
    static var lockIndex: Int {
        let stride = MemoryLayout<_PlatformLock>.stride
        return (128 + stride - 1) / stride
    }

    @inlinable
    static func create(_ initial: sending State) -> _LockedStorage {
        let buffer = create(minimumCapacity: lockIndex + 1) { buffer in
            buffer.withUnsafeMutablePointerToElements { _initializeLock($0 + lockIndex) }
            return initial
        }
        return unsafeDowncast(buffer, to: _LockedStorage.self)
    }

    @inlinable @inline(__always)
    func withLock<R>(_ body: (inout State) -> R) -> R {
        withUnsafeMutablePointers { state, elements in
            let lock = elements + Self.lockIndex
            _lock(lock)
            defer { _unlock(lock) }
            return body(&state.pointee)
        }
    }

    deinit {
        withUnsafeMutablePointerToElements { _destroyLock($0 + Self.lockIndex) }
    }
}

@inlinable @inline(__always)
func _initializeLock(_ lock: UnsafeMutablePointer<_PlatformLock>) {
    #if canImport(os)
    lock.initialize(to: os_unfair_lock_s())
    #else
    lock.initialize(to: pthread_mutex_t())
    pthread_mutex_init(lock, nil)
    #endif
}

@inlinable @inline(__always)
func _lock(_ lock: UnsafeMutablePointer<_PlatformLock>) {
    #if canImport(os)
    os_unfair_lock_lock(lock)
    #else
    pthread_mutex_lock(lock)
    #endif
}

@inlinable @inline(__always)
func _unlock(_ lock: UnsafeMutablePointer<_PlatformLock>) {
    #if canImport(os)
    os_unfair_lock_unlock(lock)
    #else
    pthread_mutex_unlock(lock)
    #endif
}

@usableFromInline
func _destroyLock(_ lock: UnsafeMutablePointer<_PlatformLock>) {
    #if !canImport(os)
    pthread_mutex_destroy(lock)
    #endif
    lock.deinitialize(count: 1)
}
