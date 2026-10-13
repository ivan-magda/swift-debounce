# Scenarios: a new Task per value (simple) vs one long-lived Task per burst vs swift-debounce
CPU: 10 cores, Version 26.7.1 (Build 25G241)

## 1. Burst: 1000 emits in a tight loop (1 thread, debounce 10 ms)
| metric (median of 15) | simple | long-lived Task | swift-debounce |
|---|---:|---:|---:|
| emit() cost, ns/call | 2063 | 576 | 41 |
| emit loop wall time, ms | 2.06 | 0.58 | 0.04 |
| first emit → output, ms | 16.93 | 14.31 | 14.57 |
| total CPU (all threads), ms | 6.12 | 0.86 | 0.37 |
| footprint growth during loop, KB | 0 | 0 | 0 |
| context switches | 37 | 10 | 8 |
| Tasks created | 1000 | 1 | n/a |
| task wake-ups | 1000 | 2 | n/a |

## 1. Burst: 10000 emits in a tight loop (1 thread, debounce 10 ms)
| metric (median of 15) | simple | long-lived Task | swift-debounce |
|---|---:|---:|---:|
| emit() cost, ns/call | 1739 | 486 | 29 |
| emit loop wall time, ms | 17.39 | 4.86 | 0.29 |
| first emit → output, ms | 28.53 | 15.86 | 15.12 |
| total CPU (all threads), ms | 61.99 | 5.11 | 0.63 |
| footprint growth during loop, KB | 16 | 0 | 0 |
| context switches | 340 | 11 | 10 |
| Tasks created | 10000 | 1 | n/a |
| task wake-ups | 10000 | 2 | n/a |

## 1. Burst: 100000 emits in a tight loop (1 thread, debounce 10 ms)
| metric (median of 15) | simple | long-lived Task | swift-debounce |
|---|---:|---:|---:|
| emit() cost, ns/call | 798 | 216 | 16 |
| emit loop wall time, ms | 79.82 | 21.61 | 1.57 |
| first emit → output, ms | 93.03 | 32.93 | 15.08 |
| total CPU (all threads), ms | 280.81 | 21.91 | 1.72 |
| footprint growth during loop, KB | 0 | 0 | 0 |
| context switches | 916 | 22 | 9 |
| Tasks created | 100000 | 1 | n/a |
| task wake-ups | 100000 | 3 | n/a |

## 2. Contention: 8 threads × 25 000 emits into one debouncer
| metric (median of 10) | simple | long-lived Task | swift-debounce |
|---|---:|---:|---:|
| wall time per emit, ns | 1634 | 393 | 60 |
| emit phase wall time, ms | 326.8 | 78.6 | 12.1 |
| total CPU, ms | 2236.9 | 516.4 | 88.5 |
| context switches | 59391 | 8752 | 134 |
| Tasks created | 200000 | 1 | n/a |
| task wake-ups | 200000 | 4 | n/a |
| outputs delivered | 1 | 1 | 1 |

(typing baseline without any debouncer: 19.94 ms CPU)

## 3. Typing: 200 events every 5 ms, debounce 50 ms (~1 s of real time)
| metric (median of 7) | simple | long-lived Task | swift-debounce |
|---|---:|---:|---:|
| total CPU incl. baseline, ms | 31.10 | 21.65 | 21.22 |
| context switches | 889 | 658 | 655 |
| Tasks created | 200 | 1 | n/a |
| task wake-ups | 200 | 21 | n/a |
| outputs delivered | 1 | 1 | 1 |
| output delay beyond 50 ms, ms | 3.06 | 7.86 | 10.15 |

## 4. Fan-out: 10 000 debouncers × 10 emits each
| metric (median of 7) | simple | long-lived Task | swift-debounce |
|---|---:|---:|---:|
| emit phase wall time, ms | 104.0 | 27.3 | 8.0 |
| total CPU, ms | 565.7 | 155.7 | 126.0 |
| footprint growth during emits, KB | 1760 | 0 | 0 |
| context switches | 8716 | 3181 | 2550 |
| Tasks created | 100000 | 10000 | n/a |
| task wake-ups | 100000 | 20000 | n/a |

## 5. Latency: 20 rapid emits, delay from last emit to output beyond 30 ms debounce (40 reps)
| | p50, ms | p95, ms | max, ms |
|---|---:|---:|---:|
| simple | 9.56 | 11.53 | 12.88 |
| long-lived Task | 9.57 | 10.88 | 15.41 |
| package | 9.90 | 11.58 | 12.13 |
