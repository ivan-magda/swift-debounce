# Lock storage for the package — median of 9 interleaved rounds
| storage | lock, 1 thread ns | lock, 8 threads ns | send, 1 thread ns | send, 8 threads wall ns | send, 8 threads CPU ns | ctx switches | heap bytes / debouncer |
|---|---:|---:|---:|---:|---:|---:|---:|
| Synchronization.Mutex (iOS 18+) | 8.0 | 27.2 | 13.2 | 86.8 | 662.4 | 561 | 128 |
| ManagedBuffer + os_unfair_lock (iOS 13+) | 7.6 | 24.9 | 13.1 | 79.7 | 602.8 | 573 | 160 |
| ManagedBuffer + os_unfair_lock, lock padded 128 B (iOS 13+) | 7.6 | 37.1 | 13.2 | 54.2 | 405.3 | 473 | 288 |
| OSAllocatedUnfairLock (iOS 16+) | 7.6 | 23.6 | 13.1 | 84.6 | 645.3 | 573 | 160 |
| os_unfair_lock, separate heap alloc (iOS 13+) | 7.6 | 38.4 | 17.9 | 65.7 | 497.9 | 500 | 144 |

min–max across rounds:
- Synchronization.Mutex (iOS 18+): send 1 thread 13.1–13.3 ns; send 8 threads wall 77.5–94.3 ns, CPU 589.0–721.9 ns
- ManagedBuffer + os_unfair_lock (iOS 13+): send 1 thread 13.0–13.2 ns; send 8 threads wall 73.7–97.7 ns, CPU 556.3–758.6 ns
- ManagedBuffer + os_unfair_lock, lock padded 128 B (iOS 13+): send 1 thread 13.2–13.3 ns; send 8 threads wall 51.9–62.6 ns, CPU 390.5–462.8 ns
- OSAllocatedUnfairLock (iOS 16+): send 1 thread 13.1–13.2 ns; send 8 threads wall 71.3–118.8 ns, CPU 531.7–917.9 ns
- os_unfair_lock, separate heap alloc (iOS 13+): send 1 thread 17.8–18.0 ns; send 8 threads wall 62.7–67.5 ns, CPU 482.3–516.6 ns
