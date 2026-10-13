# How it works

The rules both types follow, the state machine behind them, and why `send` is cheap.

## Rules

Both ``Debouncer`` and ``Throttler`` follow the same rules:

1. **One action at a time.** The action never runs concurrently with itself. A value that becomes due while the action runs waits for it to return.
2. **Only the latest value waits.** If more values become due while the action runs, each one replaces the previous one. Nothing queues up.
3. **Cancel drops, and waits.** ``Debouncer/cancel()`` and `deinit` drop the pending value and cancel the running action. Cancellation is cooperative, so if the action keeps going, the next action waits until it returns.
4. **No late starts.** If you cancel on the action's actor, for example the main actor, an action that was about to start never starts. The check happens on that actor right before the call, with no suspension in between.
5. **One task per burst.** A single background task waits for the whole burst, instead of a new task for every value.

A throttler also starts the action at most once per interval, measured from the start of each action.

## The debouncer's states

![The trailing debouncer's states: Idle, Waiting, Running, and Running with a pending value, with the transitions between them.](debouncer-states.svg)

`send` moves an idle debouncer to *Waiting* and starts the background task. Each new value restarts the timer. When no value arrives for `dueTime`, the task runs the action. A value that arrives while the action runs starts a new wait; when the action returns, the task either runs it right away, if its time has come, or keeps waiting.

The state machines are plain structs that take the current time as a parameter, so the tests check every transition without sleeping. Property tests also run thousands of random scenarios through them and check the rules above.

## Why sending is cheap

`send` takes a lock, updates the state machine, and returns. It creates a task only when a burst begins. The [benchmarks](https://github.com/ivan-magda/swift-debounce/tree/main/Benchmarks) measured each choice:

- **The clock.** Deadlines are stored as `UInt64` ticks of `mach_continuous_time`. `ContinuousClock.Instant` comes from a library built with library evolution and isn't `@frozen`, so every value holding it needs runtime metadata lookups. That alone made `send` cost about 190 ns.
- **Specialization.** `send` is `@inlinable`, so your app compiles a version specialized for your value type. Without it, a generic class from a package runs unspecialized: about 110 ns instead of 13.
- **The lock.** An `os_unfair_lock` and the state share one allocation, which works from iOS 13. `Synchronization.Mutex` compiles to the same calls on Apple platforms but needs iOS 18. The lock sits 128 bytes away from the state, so the two never share a cache line. Under contention from 8 threads, that made `send` about 1.5 times faster.

## Task inheritance

The background task inherits the priority and task-local values of the code that started the burst, the same way `Task { }` does.
