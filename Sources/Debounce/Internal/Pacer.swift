/// The locked state shared by a pacer and its worker.
@usableFromInline
struct _PacerState<Machine: _PacingMachine>: Sendable {
    @usableFromInline var machine: Machine
    /// The current worker, or the last cancelled one that may still be finishing its action.
    @usableFromInline var worker: Task<Void, Never>?
    /// Bumped by `cancel()`. A worker only touches the state of its own generation.
    @usableFromInline var generation: UInt64 = 0

    @inlinable
    init(machine: Machine) {
        self.machine = machine
    }
}

/// The user's action. A separate case for `Void` keeps the closure's own isolation: wrapping a
/// `() async -> Void` into a `(Void) async -> Void` would create a new, nonisolated closure.
@usableFromInline
enum _Action<Value> {
    case value(@isolated(any) (Value) async -> Void)
    case void(@isolated(any) () async -> Void)
}

/// The engine behind ``Debouncer`` and ``Throttler``.
///
/// One worker task runs per active period (from idle back to idle), not one per value. The worker
/// sleeps until the machine's next deadline, runs the action, and asks the machine again.
///
/// The public types keep a direct reference to `storage` so `send` reaches the lock in one hop.
/// The worker keeps the core alive, not the public object, so the owner's `deinit` still runs.
@usableFromInline
final class _PacerCore<Machine: _PacingMachine>: Sendable {
    /// Only accessed through its lock.
    @usableFromInline nonisolated(unsafe) let storage: _LockedStorage<_PacerState<Machine>>
    /// Not `Sendable`: the caller hands it over (`sending`) and it's only ever called serially,
    /// one action at a time, so it's never used from two threads at once.
    nonisolated(unsafe) let action: _Action<Machine.Value>
    let timebase: _Timebase

    init(machine: Machine, timebase: _Timebase, action: sending _Action<Machine.Value>) {
        self.storage = .create(_PacerState(machine: machine))
        self.timebase = timebase
        self.action = action
    }

    /// Starts a worker. Called under the lock when the machine asks for one.
    ///
    /// If a cancelled worker is still running its action, the new worker waits for it first,
    /// so two actions never run at the same time, even across `cancel()`.
    @usableFromInline
    func startWorker(_ state: inout _PacerState<Machine>) {
        let previous = state.worker
        let generation = state.generation
        state.worker = Task {
            await previous?.value
            await self.run(generation: generation)
        }
    }

    private func run(generation: UInt64) async {
        while true {
            let now = _MonotonicClock.now()
            let step: _Step<Machine.Value> = storage.withLock { state in
                guard state.generation == generation else {
                  return .exit
                }

                let step = state.machine.next(now: now)
                if case .exit = step {
                  state.worker = nil
                }

                return step
            }

            switch step {
            case .exit:
                return
            case .sleep(let deadline):
                let now = _MonotonicClock.now()
                guard deadline > now else {
                  continue
                }

                do {
                    try await Task.sleep(nanoseconds: timebase.nanoseconds(fromTicks: deadline - now))
                } catch {
                    return // cancelled: `cancel()` already reset the state
                }
            case .run(let value):
                let isCurrent: @Sendable () -> Bool = { [self] in
                    storage.withLock {
                      $0.generation == generation
                    }
                }

                switch action {
                case .value(let action):
                    await _runIfCurrent(isolation: action.isolation, isCurrent, action, value)
                case .void(let action):
                    await _runIfCurrent(isolation: action.isolation, isCurrent, action)
                }
            }
        }
    }

    /// Drops pending values and cancels the running action.
    @usableFromInline
    func cancel() {
        let worker = storage.withLock { state in
            state.generation &+= 1
            state.machine.reset()
            return state.worker // kept so the next worker can wait for it to finish
        }
        // Outside the lock: cancellation handlers run synchronously and may call back into us.
        worker?.cancel()
    }
}

/// Runs `action` on its own actor, but only if the worker is still current.
///
/// The check happens on the action's actor right before the call, with no suspension in between.
/// So if `cancel()` (or the owner's `deinit`) runs on that actor first, the action never starts,
/// even when the worker was already on its way.
///
/// The action is called directly here, not through a wrapper closure: a closure created in the
/// worker would be nonisolated and add a hop between the check and the call.
private func _runIfCurrent<Value: Sendable>(
    isolation: isolated (any Actor)?,
    _ isCurrent: @Sendable () -> Bool,
    _ action: @isolated(any) (Value) async -> Void,
    _ value: Value
) async {
    guard isCurrent() else {
      return
    }
    await action(value)
}

private func _runIfCurrent(
    isolation: isolated (any Actor)?,
    _ isCurrent: @Sendable () -> Bool,
    _ action: @isolated(any) () async -> Void
) async {
    guard isCurrent() else {
      return
    }
    await action()
}
