# Lock & emit() profiling — default build

## 1. Building blocks of emit(), single thread, ns/op
| operation | ns/op |
| --- | ---: |
| ContinuousClock.now | 28.6 |
| SuspendingClock.now | 28.6 |
| mach_continuous_time() | 5.1 |
| clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) | 9.5 |
| mach_absolute_time() | 5.1 |

## 2. Raw locks: withLock { counter += 1 }, ns per op (wall)
| lock | 1 thread | 8 threads contended |
| --- | ---: | ---: |
| NSRecursiveLock (long-lived Task reference) | 17.1 | 37.9 |
| NSLock | 9.1 | 21.2 |
| pthread_mutex_t | 8.7 | 20.9 |
| os_unfair_lock (heap-allocated) | 8.0 | 31.9 |
| OSAllocatedUnfairLock | 8.0 | 34.4 |
| Synchronization.Mutex | 8.0 | 32.1 |
| DispatchQueue.sync (serial) | 258.3 | 2162.7 |
| DispatchSemaphore | 9.8 | 1281.9 |
| actor, `await` from nonisolated task | 81.5 | 3.6 |
| actor, `await` from @MainActor | 5749.8 | — |

## 3. Long-lived Task reference: how is emit() called?
| call style | ns/emit |
| --- | ---: |
| `any Debouncer<Int>` (first benchmark) | 188.7 |
| concrete `LongLivedTaskDebounce<Int>` | 188.3 |

## 4. Same algorithm, different lock — 1 thread × 1M emits and 8 threads × 100k emits
| variant | 1 thread, ns/emit | 8 threads, wall ns/emit | 8 threads, CPU ns/emit | ctx switches |
| --- | ---: | ---: | ---: | ---: |
| SafeStorage + NSRecursiveLock (long-lived Task reference) | 188.0 | 376.6 | 2551.5 | 33048 |
| NSRecursiveLock | 192.5 | 384.6 | 2561.6 | 32666 |
| NSLock | 184.4 | 354.3 | 2439.5 | 27328 |
| pthread_mutex_t | 179.9 | 348.9 | 2374.9 | 28214 |
| os_unfair_lock | 177.7 | 342.1 | 1384.4 | 13924 |
| OSAllocatedUnfairLock | 183.4 | 335.2 | 1361.5 | 14484 |
| Mutex (as a plain lock) | 178.1 | 340.2 | 1429.3 | 13559 |
| DispatchQueue.sync | 426.6 | 2395.4 | 2455.1 | 801942 |
| DispatchSemaphore | 179.2 | 1454.4 | 1462.0 | 800903 |
| Mutex<State>, one critical section | 207.7 | 409.1 | 1879.2 | 44478 |
| **FastDebounce: Mutex + UInt64 deadline** | 13.3 | 52.8 | 402.4 | 486 |
| actor (`await emit` from nonisolated task) | 237.6 | 807.8 | 1188.9 | 166181 |
| actor (`await emit` from @MainActor) | 6338.0 | — | — | — |
