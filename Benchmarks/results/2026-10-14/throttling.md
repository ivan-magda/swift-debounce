# Throttler — interval 20 ms unless noted, medians of 7 runs

## 1. `send` from one thread, 2M values
| type | ns per send |
|---|---:|
| Throttler (leading + trailing) | 10.5 |
| Debouncer (trailing), for comparison | 12.7 |

## 2. 8 threads × 100k sends into one throttler
| wall ns per send | CPU ns per send | context switches |
|---:|---:|---:|
| 47.4 | 358.6 | 414 |

## 3. Steady stream: a value every ~1 ms for 2 s, interval 50 ms
| starts | gap median, ms | gap min (all runs), ms | gaps under 49.5 ms | gap p95, ms | CPU ms per second (incl. the sending loop) |
|---:|---:|---:|---:|---:|---:|
| 41 | 51.03 | 49.80 | 0 of 198 | 53.06 | 48.03 |

## 4. Main-actor action, main actor blocked 30 ms of every 50 ms, a value every ~1 ms for 2 s, interval 50 ms
| starts | gap median, ms | gap min (all runs), ms | gaps under 49.5 ms |
|---:|---:|---:|---:|
| 40 | 50.63 | 50.03 | 0 of 195 |
