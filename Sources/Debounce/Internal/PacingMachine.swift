/// What the background worker should do next.
@usableFromInline
enum _Step<Value> {
    /// Run the action with this value.
    case run(Value)
    /// Nothing is due yet; sleep until this deadline (in clock ticks) and ask again.
    case sleep(until: UInt64)
    /// Nothing left to do; the worker ends.
    case exit
}

/// A pure, synchronous state machine that decides when values are delivered.
///
/// Time is passed in as `now` (clock ticks), so every transition can be tested deterministically.
/// Machines never run concurrently with themselves: all calls happen under one lock.
///
/// The worker that drives a machine guarantees the rules shared by ``Debouncer`` and ``Throttler``:
/// `next(now:)` is only called while no action is running, so actions never overlap, and a value
/// due while an action runs simply waits in the machine until the action returns.
@usableFromInline
protocol _PacingMachine<Value>: Sendable {
    associatedtype Value: Sendable

    /// Records a new value. Returns `true` when a worker must be started to deliver it.
    mutating func send(_ value: Value, now: UInt64) -> Bool

    /// Called by the worker whenever no action is running.
    mutating func next(now: UInt64) -> _Step<Value>

    /// Drops every pending value and returns to idle.
    mutating func reset()
}

// MARK: - Debounce

/// Debounce: a burst lasts until `interval` passes without a new value.
///
/// - Leading: the first value of a burst is delivered right away.
/// - Trailing: the last value of a burst is delivered once the burst is over. With both edges,
///   a burst of a single value is delivered once (on the leading edge only).
@usableFromInline
struct _DebounceMachine<Value: Sendable>: _PacingMachine {
    @usableFromInline let interval: UInt64
    @usableFromInline let edges: TriggerEdges

    /// End of the current burst; `nil` when there is no burst.
    @usableFromInline var burstDeadline: UInt64?
    /// Latest value of the current burst that the trailing edge will deliver.
    @usableFromInline var trailingValue: Value?
    /// Value that is due and waits for the worker (or for the running action to return).
    @usableFromInline var readyValue: Value?
    @usableFromInline var isWorkerActive = false

    @inlinable
    init(interval: UInt64, edges: TriggerEdges) {
        self.interval = interval
        self.edges = edges
    }

    @inlinable
    mutating func send(_ value: Value, now: UInt64) -> Bool {
        let deadline = _deadline(after: now, adding: interval)

        if let current = burstDeadline, now < current {
            burstDeadline = max(current, deadline)
            if edges.contains(.trailing) {
              trailingValue = value
            }
        } else {
            // The previous burst may have ended without the worker noticing yet: its trailing
            // value is due now. Only the latest due value is kept.
            if burstDeadline != nil, let pending = trailingValue {
              readyValue = pending
            }

            trailingValue = nil
            burstDeadline = deadline

            if edges.contains(.leading) {
                readyValue = value
            } else {
                trailingValue = value
            }
        }

        if isWorkerActive {
          return false
        }
        isWorkerActive = true

        return true
    }

    @inlinable
    mutating func next(now: UInt64) -> _Step<Value> {
        if let deadline = burstDeadline, now >= deadline {
            burstDeadline = nil
            if let value = trailingValue {
                trailingValue = nil
                readyValue = value
            }
        }

        if let value = readyValue {
            readyValue = nil
            return .run(value)
        }
        if let deadline = burstDeadline {
            return .sleep(until: deadline)
        }
        isWorkerActive = false

        return .exit
    }

    @inlinable
    mutating func reset() {
        burstDeadline = nil
        trailingValue = nil
        readyValue = nil
        isWorkerActive = false
    }
}

// MARK: - Throttle

/// Throttle: at most one action starts per `interval`.
///
/// A window opens when a value arrives while idle and is restarted every time an action starts,
/// so starts are always at least `interval` apart.
///
/// - Leading: a value that arrives while idle is delivered right away.
/// - Trailing: the latest value received during a window is delivered when the window ends.
@usableFromInline
struct _ThrottleMachine<Value: Sendable>: _PacingMachine {
    @usableFromInline let interval: UInt64
    @usableFromInline let edges: TriggerEdges

    /// End of the current window; `nil` when idle.
    @usableFromInline var windowEnd: UInt64?
    @usableFromInline var trailingValue: Value?
    @usableFromInline var readyValue: Value?
    @usableFromInline var isWorkerActive = false
    /// True from the moment `next(now:)` returns `.run` until the worker calls it again,
    /// that is, while the action runs.
    @usableFromInline var isRunning = false

    @inlinable
    init(interval: UInt64, edges: TriggerEdges) {
        self.interval = interval
        self.edges = edges
    }

    @inlinable
    mutating func send(_ value: Value, now: UInt64) -> Bool {
        if let end = windowEnd, now >= end, isRunning {
            // The window ended while a slow action still runs. The next start can only happen
            // when it returns, so keep just the latest value for that moment.
            if edges.contains(.trailing) {
                trailingValue = value
            } else {
                readyValue = value
            }
        } else if let end = windowEnd, now >= end {
            // The window ended and the worker sleeps but hasn't woken up yet: settle it here.
            if let pending = trailingValue {
                // The pending value starts now and opens a new window; this value falls into it.
                readyValue = pending
                trailingValue = nil
                windowEnd = _deadline(after: now, adding: interval)
            } else {
                windowEnd = nil
            }
            receive(value, now: now)
        } else {
            receive(value, now: now)
        }

        if isWorkerActive {
            return false
        }
        isWorkerActive = true

        return true
    }

    /// Records a value: inside an open window it waits for the trailing edge, otherwise it opens one.
    @inlinable
    mutating func receive(_ value: Value, now: UInt64) {
        if windowEnd != nil {
            if edges.contains(.trailing) {
              trailingValue = value
            }
        } else {
            windowEnd = _deadline(after: now, adding: interval)
            if edges.contains(.leading) {
                readyValue = value
            } else {
                trailingValue = value
            }
        }
    }

    @inlinable
    mutating func next(now: UInt64) -> _Step<Value> {
        isRunning = false
        if let value = readyValue {
            readyValue = nil
            windowEnd = _deadline(after: now, adding: interval)
            isRunning = true
            return .run(value)
        }

        if let end = windowEnd {
            if now < end {
              return .sleep(until: end)
            }

            if let value = trailingValue {
                trailingValue = nil
                // With a leading edge the next value would otherwise start right away, closer
                // than `interval` to this start; keep a window open from this start.
                windowEnd = edges.contains(.leading) ? _deadline(after: now, adding: interval) : nil
                isRunning = true
                return .run(value)
            }

            windowEnd = nil
        }
        isWorkerActive = false

        return .exit
    }

    @inlinable
    mutating func reset() {
        windowEnd = nil
        trailingValue = nil
        readyValue = nil
        isWorkerActive = false
        isRunning = false
    }
}
