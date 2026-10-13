# Lock storage for the package — median of 9 interleaved rounds
| storage | lock, 1 thread ns | lock, 8 threads ns | send, 1 thread ns | send, 8 threads wall ns | send, 8 threads CPU ns | ctx switches | heap bytes / debouncer |
|---|---:|---:|---:|---:|---:|---:|---:|
| Synchronization.Mutex (iOS 18+) | 8.0 | 27.9 | 13.2 | 80.9 | 598.3 | 750 | 128 |
| ManagedBuffer + os_unfair_lock (iOS 13+) | 7.5 | 37.0 | 13.2 | 81.1 | 598.6 | 790 | 160 |
| ManagedBuffer + os_unfair_lock, lock padded 128 B (iOS 13+) | 7.6 | 36.7 | 13.3 | 53.5 | 379.0 | 596 | 288 |
| OSAllocatedUnfairLock (iOS 16+) | 7.6 | 36.2 | 13.2 | 75.0 | 550.8 | 760 | 160 |
| os_unfair_lock, separate heap alloc (iOS 13+) | 7.6 | 37.0 | 17.7 | 64.0 | 496.7 | 631 | 144 |

min–max across rounds:
- Synchronization.Mutex (iOS 18+): send 1 thread 13.1–13.4 ns; send 8 threads wall 61.6–120.9 ns, CPU 453.7–921.9 ns
- ManagedBuffer + os_unfair_lock (iOS 13+): send 1 thread 13.0–13.6 ns; send 8 threads wall 42.7–107.2 ns, CPU 250.9–825.6 ns
- ManagedBuffer + os_unfair_lock, lock padded 128 B (iOS 13+): send 1 thread 13.1–13.5 ns; send 8 threads wall 47.9–56.7 ns, CPU 330.7–432.8 ns
- OSAllocatedUnfairLock (iOS 16+): send 1 thread 13.0–13.5 ns; send 8 threads wall 57.3–93.2 ns, CPU 363.8–713.7 ns
- os_unfair_lock, separate heap alloc (iOS 13+): send 1 thread 17.5–17.8 ns; send 8 threads wall 61.5–68.1 ns, CPU 457.8–517.2 ns
