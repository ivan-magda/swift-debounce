#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A monotonic clock that keeps counting while the device sleeps, read in platform ticks.
///
/// Storing ticks as `UInt64` keeps deadline arithmetic on plain integers.
/// `ContinuousClock.Instant` has an opaque layout across module boundaries,
/// even in code specialized for the input type. On Darwin, our clock benchmark
/// measured lower overhead for `mach_continuous_time()` than for
/// `ContinuousClock.now`. See `Benchmarks/README.md`.
@usableFromInline
enum _MonotonicClock {
    @inlinable @inline(__always)
    static func now() -> UInt64 {
        #if canImport(Darwin)
        return mach_continuous_time()
        #else
        var time = timespec()
        clock_gettime(CLOCK_BOOTTIME, &time)
        return UInt64(time.tv_sec) &* 1_000_000_000 &+ UInt64(time.tv_nsec)
        #endif
    }
}

/// Adds a duration to a deadline without trapping on overflow.
@inlinable @inline(__always)
func _deadline(after now: UInt64, adding ticks: UInt64) -> UInt64 {
    let (sum, overflow) = now.addingReportingOverflow(ticks)
    return overflow ? .max : sum
}

/// Converts between nanoseconds and clock ticks.
@usableFromInline
struct _Timebase: Sendable {
    /// `nanoseconds = ticks * numer / denom`
    let numer: Double
    let denom: Double

    static let current: _Timebase = {
        #if canImport(Darwin)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return _Timebase(numer: Double(info.numer), denom: Double(info.denom))
        #else
        return _Timebase(numer: 1, denom: 1)
        #endif
    }()

    /// The largest interval accepted, in nanoseconds (about 146 years). Larger values are clamped.
    static let maxNanoseconds: Double = 0x1p62

    func ticks(fromNanoseconds nanoseconds: Double) -> UInt64 {
        let ticks = min(nanoseconds, Self.maxNanoseconds) * denom / numer
        return UInt64(max(1, ticks.rounded(.up)))
    }

    func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        UInt64(min(Double(ticks) * numer / denom, Self.maxNanoseconds).rounded(.up))
    }
}

func _nanoseconds(fromSeconds seconds: Double) -> Double {
    precondition(seconds > 0 && seconds.isFinite, "The interval must be a positive, finite number of seconds.")
    return seconds * 1e9
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
func _nanoseconds(from duration: Duration) -> Double {
    precondition(duration > .zero, "The interval must be greater than zero.")
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1e9 + Double(attoseconds) / 1e9
}
