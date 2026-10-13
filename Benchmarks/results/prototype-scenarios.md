# Debounce: simple (Task per emit) vs optimized (state machine)
CPU: 10 cores, Version 26.7.1 (Build 25G241)

## 1. Burst: 1000 emits in a tight loop (1 thread, debounce 10 ms)
| metric (median of 15) | simple | optimized | simple / optimized |
|---|---:|---:|---:|
| emit() cost, ns/call | 1947 | 553 | 3.5x |
| emit loop wall time, ms | 1.95 | 0.55 | 3.5x |
| first emit → output, ms | 13.36 | 12.61 | 1.1x |
| total CPU (all threads), ms | 6.85 | 0.86 | 7.9x |
| footprint growth during loop, KB | 0 | 0 | — |
| context switches | 56 | 10 | 5.6x |
| Tasks created | 1000 | 1 | 1000.0x |
| task wake-ups | 1000 | 2 | 500.0x |

## 1. Burst: 10000 emits in a tight loop (1 thread, debounce 10 ms)
| metric (median of 15) | simple | optimized | simple / optimized |
|---|---:|---:|---:|
| emit() cost, ns/call | 1195 | 279 | 4.3x |
| emit loop wall time, ms | 11.95 | 2.79 | 4.3x |
| first emit → output, ms | 22.91 | 13.85 | 1.7x |
| total CPU (all threads), ms | 40.18 | 2.96 | 13.6x |
| footprint growth during loop, KB | 16 | 0 | — |
| context switches | 363 | 13 | 27.9x |
| Tasks created | 10000 | 1 | 10000.0x |
| task wake-ups | 10000 | 2 | 5000.0x |

## 1. Burst: 100000 emits in a tight loop (1 thread, debounce 10 ms)
| metric (median of 15) | simple | optimized | simple / optimized |
|---|---:|---:|---:|
| emit() cost, ns/call | 851 | 216 | 3.9x |
| emit loop wall time, ms | 85.14 | 21.62 | 3.9x |
| first emit → output, ms | 96.49 | 33.31 | 2.9x |
| total CPU (all threads), ms | 270.06 | 21.76 | 12.4x |
| footprint growth during loop, KB | 16 | 0 | — |
| context switches | 1441 | 23 | 62.7x |
| Tasks created | 100000 | 1 | 100000.0x |
| task wake-ups | 100000 | 3 | 33333.3x |

## 2. Contention: 8 threads × 25 000 emits into one debouncer
| metric (median of 10) | simple | optimized | simple / optimized |
|---|---:|---:|---:|
| wall time per emit, ns | 1686 | 397 | 4.2x |
| emit phase wall time, ms | 337.1 | 79.4 | 4.2x |
| total CPU, ms | 2281.6 | 511.8 | 4.5x |
| context switches | 61373 | 9390 | 6.5x |
| Tasks created | 200000 | 1 | 200000.0x |
| task wake-ups | 200000 | 5 | 40000.0x |
| outputs delivered | 1 | 1 | 1.0x |

(typing baseline without any debouncer: 18.99 ms CPU)

## 3. Typing: 200 events every 5 ms, debounce 50 ms (~1 s of real time)
| metric (median of 7) | simple | optimized | simple / optimized |
|---|---:|---:|---:|
| total CPU incl. baseline, ms | 27.54 | 20.85 | 1.3x |
| context switches | 959 | 685 | 1.4x |
| Tasks created | 200 | 1 | 200.0x |
| task wake-ups | 200 | 21 | 9.5x |
| outputs delivered | 1 | 1 | 1.0x |
| output delay beyond 50 ms, ms | 3.39 | 1.30 | 2.6x |

## 4. Fan-out: 10 000 debouncers × 10 emits each
| metric (median of 7) | simple | optimized | simple / optimized |
|---|---:|---:|---:|
| emit phase wall time, ms | 126.5 | 27.0 | 4.7x |
| total CPU, ms | 674.6 | 162.7 | 4.1x |
| footprint growth during emits, KB | 672 | 0 | — |
| context switches | 9595 | 3169 | 3.0x |
| Tasks created | 100000 | 10000 | 10.0x |
| task wake-ups | 100000 | 20000 | 5.0x |

## 5. Latency: 20 rapid emits, delay from last emit to output beyond 30 ms debounce (40 reps)
| | p50, ms | p95, ms | max, ms |
|---|---:|---:|---:|
| simple | 4.91 | 5.35 | 5.84 |
| optimized | 5.07 | 5.28 | 5.76 |
