# Throttler — interval 20 ms unless noted, medians of 7 runs

## 1. `send` from one thread, 2M values
| type | ns per send |
|---|---:|
| Throttler (leading + trailing) | 10.9 |
| Debouncer (trailing), for comparison | 12.4 |

## 2. 8 threads × 100k sends into one throttler
| wall ns per send | CPU ns per send | context switches |
|---:|---:|---:|
| 45.3 | 297.0 | 626 |

## 3. Steady stream: a value every ~1 ms for 2 s, interval 50 ms
| starts | gap median, ms | gap min (all runs), ms | gaps under 49.5 ms | gap p95, ms | CPU ms per second (incl. the sending loop) |
|---:|---:|---:|---:|---:|---:|
| 40 | 51.13 | 50.02 | 0 of 197 | 52.84 | 47.15 |

## 4. Main-actor action, main actor blocked 30 ms of every 50 ms, a value every ~1 ms for 2 s, interval 50 ms
| starts | gap median, ms | gap min (all runs), ms | gaps under 49.5 ms |
|---:|---:|---:|---:|
| 41 | 50.97 | 20.04 | 47 of 200 |
