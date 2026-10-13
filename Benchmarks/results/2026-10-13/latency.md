# Latency: how late the action runs after a 50 ms quiet period (30 bursts each, interleaved)
| pattern | implementation | median, ms | p95, ms |
|---|---|---:|---:|
| 1 value | simple | 1.01 | 2.07 |
| 1 value | long-lived Task | 1.04 | 2.16 |
| 1 value | swift-debounce | 1.38 | 2.60 |
| 20 values at once | simple | 0.96 | 2.07 |
| 20 values at once | long-lived Task | 1.18 | 3.32 |
| 20 values at once | swift-debounce | 1.19 | 1.70 |
| 60 values, one every 5 ms | simple | 1.02 | 2.03 |
| 60 values, one every 5 ms | long-lived Task | 0.77 | 1.91 |
| 60 values, one every 5 ms | swift-debounce | 1.08 | 2.38 |
