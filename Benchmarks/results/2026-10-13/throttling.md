# Throttler — interval 20 ms unless noted, medians of 7 runs

## 1. `send` from one thread, 2M values
| type | ns per send |
|---|---:|
| Throttler (leading + trailing) | 10.5 |
| Debouncer (trailing), for comparison | 12.6 |

## 2. 8 threads × 100k sends into one throttler
| wall ns per send | CPU ns per send | context switches |
|---:|---:|---:|
| 48.0 | 362.3 | 429 |

## 3. Steady stream: a value every ~1 ms for 2 s, interval 50 ms
| starts | gap median, ms | gap min, ms | gap p95, ms | CPU ms per second (incl. the sending loop) |
|---:|---:|---:|---:|---:|
| 41 | 50.82 | 50.03 | 52.60 | 51.22 |
