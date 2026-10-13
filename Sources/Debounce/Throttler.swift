#if canImport(Foundation)
import Foundation
#endif

/// Runs an action at most once per interval, however often values arrive.
///
/// Call ``send(_:)`` as often as you like, from any thread, without `await`. Unlike a
/// ``Debouncer``, a throttler keeps running the action while values keep coming, at a steady pace.
/// It suits scroll positions, download progress, or saving a draft while the user types.
///
/// ```swift
/// let progress = Throttler(for: 0.25) { @MainActor (fraction: Double) in
///     progressView.progress = Float(fraction)
/// }
///
/// for await fraction in download.progress {
///     progress.send(fraction) // the view updates at most four times a second
/// }
/// ```
///
/// By default both edges are used: a value that arrives while idle runs right away, and the latest
/// value received during an interval runs when the interval ends. Pass ``TriggerEdges/leading`` or
/// ``TriggerEdges/trailing`` to use only one of them.
///
/// The throttler follows a few rules:
/// - Two starts of the action are always at least `interval` apart. The interval is measured from
///   the start of each action.
/// - The action never runs concurrently with itself. If it takes longer than the interval, the
///   next one starts as soon as it returns, with the latest value.
/// - ``cancel()`` and `deinit` drop the pending value and cancel the running action. If they happen
///   on the action's actor, for example the main actor, the action doesn't start afterwards.
/// - The action runs on its own actor: a `@MainActor` closure runs on the main actor, while the
///   waiting happens off the main thread.
///
/// The background task that does the waiting inherits the priority and task-local values of the
/// code that sent the value that woke it.
public final class Throttler<Value: Sendable>: Sendable {
    /// Same object as `core.storage`, kept here so `send` reaches the lock in one hop.
    /// Only accessed through its lock.
    @usableFromInline nonisolated(unsafe) let storage: _LockedStorage<_PacerState<_ThrottleMachine<Value>>>
    @usableFromInline let core: _PacerCore<_ThrottleMachine<Value>>

    /// Creates a throttler that runs the action at most once every `interval` seconds.
    ///
    /// ```swift
    /// let track = Throttler(for: 1.0) { (offset: CGFloat) in
    ///     await analytics.trackScroll(offset)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - interval: The minimum time, in seconds, between two starts of the action.
    ///     Must be greater than zero; otherwise the program stops.
    ///   - edges: Which values to run within an interval. Defaults to both
    ///     ``TriggerEdges/leading`` and ``TriggerEdges/trailing``. Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    public convenience init(
        for interval: TimeInterval,
        edges: TriggerEdges = [.leading, .trailing],
        @_inheritActorContext action: sending @escaping @isolated(any) (Value) async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(fromSeconds: interval), edges: edges, action: .value(action))
    }

    /// Creates a throttler that runs the action at most once per `interval`.
    ///
    /// ```swift
    /// let progress = Throttler(for: .milliseconds(250)) { @MainActor (fraction: Double) in
    ///     progressView.progress = Float(fraction)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - interval: The minimum time between two starts of the action. Must be greater than zero; otherwise the program stops.
    ///   - edges: Which values to run within an interval. Defaults to both
    ///     ``TriggerEdges/leading`` and ``TriggerEdges/trailing``. Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public convenience init(
        for interval: Duration,
        edges: TriggerEdges = [.leading, .trailing],
        @_inheritActorContext action: sending @escaping @isolated(any) (Value) async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(from: interval), edges: edges, action: .value(action))
    }

    init(nanoseconds: Double, edges: TriggerEdges, action: sending _Action<Value>) {
        precondition(!edges.isEmpty, "Pass at least one edge, or the action would never run.")
        let timebase = _Timebase.current
        let machine = _ThrottleMachine<Value>(interval: timebase.ticks(fromNanoseconds: nanoseconds), edges: edges)
        core = _PacerCore(machine: machine, timebase: timebase, action: action)
        storage = core.storage
    }

    /// Sends a value to the throttler.
    ///
    /// Returns immediately. Safe to call from any thread or actor.
    ///
    /// - Parameter value: The value to deliver. With the trailing edge, it replaces the value that waits
    ///   for the end of the interval. With only the leading edge, a value sent during a interval is dropped.
    @inlinable
    public func send(_ value: Value) {
        let now = _MonotonicClock.now()
        storage.withLock { state in
            if state.machine.send(value, now: now) {
              core.startWorker(&state)
            }
        }
    }

    /// Drops the pending value and cancels the action if it's running.
    ///
    /// Cancellation is cooperative: a running action stops at its next cancellation check. The next
    /// action, if you send more values, starts only after it returns. You can keep using the
    /// throttler after calling this method.
    public func cancel() {
        core.cancel()
    }

    deinit {
        core.cancel()
    }
}

extension Throttler where Value == Void {
    /// Creates a throttler for signals that carry no value.
    ///
    /// ```swift
    /// let refresh = Throttler(for: 2.0) { await feed.refresh() }
    /// refresh.send()
    /// ```
    ///
    /// - Parameters:
    ///   - interval: The minimum time, in seconds, between two starts of the action. Must be greater than zero; otherwise the program stops.
    ///   - edges: Which values to run within an interval. Defaults to both ``TriggerEdges/leading``
    ///     and ``TriggerEdges/trailing``. Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    public convenience init(
        for interval: TimeInterval,
        edges: TriggerEdges = [.leading, .trailing],
        @_inheritActorContext action: sending @escaping @isolated(any) () async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(fromSeconds: interval), edges: edges, action: .void(action))
    }

    /// Creates a throttler for signals that carry no value.
    ///
    /// - Parameters:
    ///   - interval: The minimum time between two starts of the action. Must be greater than zero; otherwise the program stops.
    ///   - edges: Which values to run within an interval. Defaults to both ``TriggerEdges/leading``
    ///     and ``TriggerEdges/trailing``. Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public convenience init(
        for interval: Duration,
        edges: TriggerEdges = [.leading, .trailing],
        @_inheritActorContext action: sending @escaping @isolated(any) () async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(from: interval), edges: edges, action: .void(action))
    }

    /// Sends a signal that carries no value.
    @inlinable
    public func send() {
        send(())
    }
}
