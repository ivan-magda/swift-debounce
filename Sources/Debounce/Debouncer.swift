#if canImport(Foundation)
import Foundation
#endif

/// Runs an action only after values stop arriving for a given time.
///
/// Call ``send(_:)`` as often as you like, from any thread, without `await`. The action runs with
/// the last value once `dueTime` has passed without a new one. This is the classic behavior for a
/// search field: wait until the user stops typing, then search once.
///
/// ```swift
/// let search = Debouncer(for: 0.3) { @MainActor (query: String) in
///     await model.search(query)
/// }
///
/// search.send("S")
/// search.send("Sw")
/// search.send("Swift") // only "Swift" is searched, 0.3 s after this call
/// ```
///
/// Pass ``TriggerEdges/leading`` to run on the first value right away and ignore the rest of the
/// burst instead, for example to protect a button from double taps.
///
/// The debouncer follows a few rules:
/// - The action never runs concurrently with itself. A value that becomes due while the action is
///   still running waits for it to return. Only the latest such value is kept.
/// - ``cancel()`` and `deinit` drop the pending value and cancel the running action. If they happen
///   on the action's actor, for example the main actor, the action doesn't start afterwards.
/// - The action runs on its own actor: a `@MainActor` closure runs on the main actor, while the
///   waiting happens off the main thread.
///
/// The background task that does the waiting inherits the priority and task-local values of the
/// code that sent the first value of a burst.
public final class Debouncer<Value: Sendable>: Sendable {
    /// Same object as `core.storage`, kept here so `send` reaches the lock in one hop.
    /// Only accessed through its lock.
    @usableFromInline nonisolated(unsafe) let storage: _LockedStorage<_PacerState<_DebounceMachine<Value>>>
    @usableFromInline let core: _PacerCore<_DebounceMachine<Value>>

    /// Creates a debouncer that waits `dueTime` seconds after the last value.
    ///
    /// ```swift
    /// let save = Debouncer(for: 1.0) { (text: String) in
    ///     await store.save(text)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - dueTime: How long, in seconds, values must stop arriving before the action runs.
    ///     Must be greater than zero; otherwise the program stops.
    ///   - edges: When to run the action within a burst. Defaults to ``TriggerEdges/trailing``.
    ///     Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    public convenience init(
        for dueTime: TimeInterval,
        edges: TriggerEdges = .trailing,
        @_inheritActorContext action: sending @escaping @isolated(any) (Value) async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(fromSeconds: dueTime), edges: edges, action: .value(action))
    }

    /// Creates a debouncer that waits `dueTime` after the last value.
    ///
    /// ```swift
    /// let search = Debouncer(for: .milliseconds(300)) { @MainActor (query: String) in
    ///     await model.search(query)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - dueTime: How long values must stop arriving before the action runs.
    ///     Must be greater than zero; otherwise the program stops.
    ///   - edges: When to run the action within a burst. Defaults to ``TriggerEdges/trailing``.
    ///     Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public convenience init(
        for dueTime: Duration,
        edges: TriggerEdges = .trailing,
        @_inheritActorContext action: sending @escaping @isolated(any) (Value) async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(from: dueTime), edges: edges, action: .value(action))
    }

    init(nanoseconds: Double, edges: TriggerEdges, action: sending _Action<Value>) {
        precondition(!edges.isEmpty, "Pass at least one edge, or the action would never run.")
        let timebase = _Timebase.current
        let machine = _DebounceMachine<Value>(interval: timebase.ticks(fromNanoseconds: nanoseconds), edges: edges)
        core = _PacerCore(machine: machine, timebase: timebase, action: action)
        storage = core.storage
    }

    /// Sends a value to the debouncer.
    ///
    /// Returns immediately. Safe to call from any thread or actor.
    ///
    /// - Parameter value: The value to deliver. With the trailing edge, it replaces the value that waits
    ///   for the end of the burst. With only the leading edge, a value sent during a burst is dropped.
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
    /// debouncer after calling this method.
    public func cancel() {
        core.cancel()
    }

    deinit {
        core.cancel()
    }
}

extension Debouncer where Value == Void {
    /// Creates a debouncer for signals that carry no value.
    ///
    /// ```swift
    /// let reload = Debouncer(for: 0.5) { await feed.reload() }
    /// reload.send()
    /// ```
    ///
    /// - Parameters:
    ///   - dueTime: How long, in seconds, signals must stop arriving before the action runs. Must be greater than zero; otherwise the program stops.
    ///   - edges: When to run the action within a burst. Defaults to ``TriggerEdges/trailing``.
    ///     Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    public convenience init(
        for dueTime: TimeInterval,
        edges: TriggerEdges = .trailing,
        @_inheritActorContext action: sending @escaping @isolated(any) () async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(fromSeconds: dueTime), edges: edges, action: .void(action))
    }

    /// Creates a debouncer for signals that carry no value.
    ///
    /// - Parameters:
    ///   - dueTime: How long signals must stop arriving before the action runs. Must be greater than zero; otherwise the program stops.
    ///   - edges: When to run the action within a burst. Defaults to ``TriggerEdges/trailing``.
    ///     Must not be empty.
    ///   - action: The work to run. It runs on its own actor, if it has one.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public convenience init(
        for dueTime: Duration,
        edges: TriggerEdges = .trailing,
        @_inheritActorContext action: sending @escaping @isolated(any) () async -> Void
    ) {
        self.init(nanoseconds: _nanoseconds(from: dueTime), edges: edges, action: .void(action))
    }

    /// Sends a signal that carries no value.
    @inlinable
    public func send() {
        send(())
    }
}
