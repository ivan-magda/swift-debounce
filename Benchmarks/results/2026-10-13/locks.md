# Lock & emit() profiling — default build

## 1. Building blocks of emit(), single thread, ns/op
| operation | ns/op |
| --- | ---: |
| ContinuousClock.now | 28.9 |
| SuspendingClock.now | 28.3 |
| mach_continuous_time() | 5.0 |
| clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) | 9.5 |
| mach_absolute_time() | 5.1 |

## 2. Raw locks: withLock { counter += 1 }, ns per op (wall)
| lock | 1 thread | 8 threads contended |
| --- | ---: | ---: |
| NSRecursiveLock (long-lived Task reference) | 17.0 | 37.0 |
| NSLock | 9.1 | 20.7 |
| pthread_mutex_t | 8.9 | 20.7 |
| os_unfair_lock (heap-allocated) | 8.2 | 38.4 |
| OSAllocatedUnfairLock | 8.1 | 27.7 |
| Synchronization.Mutex | 7.9 | 27.9 |
| DispatchQueue.sync (serial) | 257.0 | 2142.5 |
| DispatchSemaphore | 9.6 | 1297.8 |
| actor, `await` from nonisolated task | 79.7 | 3.5 |
| actor, `await` from @MainActor | 5762.5 | — |

## 3. Long-lived Task reference: how is emit() called?
| call style | ns/emit |
| --- | ---: |
| `any DebounceUnderTest<Int>` (first benchmark) | 187.1 |
| concrete `LongLivedTaskDebounce<Int>` | 187.1 |

## 4. Same algorithm, different lock — 1 thread × 1M emits and 8 threads × 100k emits
| variant | 1 thread, ns/emit | 8 threads, wall ns/emit | 8 threads, CPU ns/emit | ctx switches |
| --- | ---: | ---: | ---: | ---: |
| SafeStorage + NSRecursiveLock (long-lived Task reference) | 187.5 | 374.4 | 2534.5 | 27858 |
| NSRecursiveLock | 129.4 | 251.1 | 1741.1 | 19069 |
| NSLock | 122.2 | 233.5 | 1612.6 | 21530 |
| pthread_mutex_t | 95.6 | 194.2 | 1346.1 | 15856 |
| os_unfair_lock | 94.4 | 180.5 | 1223.8 | 1683 |
| OSAllocatedUnfairLock | 94.1 | 186.3 | 1274.0 | 2053 |
| Mutex (as a plain lock) | 93.7 | 188.2 | 1190.8 | 2666 |
| DispatchQueue.sync | 368.8 | 2339.3 | 2413.2 | 801789 |
| DispatchSemaphore | 95.2 | 1362.0 | 1368.6 | 800728 |
| Mutex<State>, one critical section | 81.2 | 148.8 | 992.1 | 1873 |
| **swift-debounce `Debouncer`** | 13.9 | 49.9 | 382.2 | 401 |
| actor (`await emit` from nonisolated task) | 161.7 | 783.5 | 1143.3 | 135742 |
| actor (`await emit` from @MainActor) | 6310.5 | — | — | — |
