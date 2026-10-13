#if canImport(SwiftUI)
import Debounce

/// A value change, numbered so the state can tell which change an action handled.
struct _Change<Value: Sendable>: Sendable {
    let sequence: UInt64
    let value: Value
}

/// What the modifier was configured with. A change between view updates replaces the pacer.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
struct _PacingConfiguration: Equatable, Sendable {
    enum Kind: Sendable { case debounce, throttle }

    let kind: Kind
    let interval: Duration
    let edges: TriggerEdges
}

/// The part of ``Debouncer`` and ``Throttler`` the modifier uses. Tests use a fake.
protocol _ChangePacer<Value>: AnyObject, Sendable {
    associatedtype Value: Sendable
    func send(_ value: Value)
    func cancel()
}

extension Debouncer: _ChangePacer {}
extension Throttler: _ChangePacer {}

/// The state behind one `onChange(of:debounce:)` or `onChange(of:throttle:)` modifier.
///
/// The modifier keeps it in `@State`, so it lives exactly as long as the view's identity. It owns
/// the pacer: when SwiftUI releases the state, the pacer's `deinit` drops the pending value and
/// cancels the running action.
///
/// Nothing else holds the state strongly. The pacer's action captures it weakly and lets go of it
/// before awaiting the user's action, so a running action can't keep a removed view's work alive.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
@MainActor
final class _ChangePacingState<Value: Equatable & Sendable> {
    typealias Action = @MainActor (_ oldValue: Value, _ newValue: Value) async -> Void
    typealias Deliver = @MainActor @Sendable (_Change<Value>) async -> Void
    typealias MakePacer = @MainActor (_PacingConfiguration, @escaping Deliver) -> any _ChangePacer<_Change<Value>>

    private let makePacer: MakePacer
    private var configuration: _PacingConfiguration?
    private var action: Action?
    private var pacer: (any _ChangePacer<_Change<Value>>)?
    private weak var handle: PacingHandle?
    /// Keeps actions from overlapping when the configuration changes and a new pacer starts while
    /// the old pacer's cancelled action is still running.
    private let gate = _ActionGate()

    /// The value of the last action that finished without being cancelled: the next `oldValue`.
    private var handled: Value?
    private var handledSequence: UInt64 = 0
    private var latest: Value?
    private var latestSequence: UInt64 = 0
    /// Changes up to this one were cancelled through the handle and must not be delivered again.
    private var dismissedSequence: UInt64 = 0

    nonisolated init(makePacer: @escaping MakePacer = _ChangePacingState.livePacer) {
        self.makePacer = makePacer
    }

    /// Called on every view update with the modifier's current arguments.
    func update(
        value: Value,
        configuration: _PacingConfiguration,
        handle: PacingHandle?,
        action: @escaping Action
    ) {
        if handled == nil {
            handled = value
            latest = value
        }
        self.action = action

        if handle !== self.handle {
            self.handle?.detach(self)
            handle?.attach(self)
            self.handle = handle
        }

        if configuration != self.configuration {
            self.configuration = configuration
            if let old = pacer {
                old.cancel()
                pacer = nil
                if latestSequence > max(handledSequence, dismissedSequence), let latest {
                    currentPacer().send(_Change(sequence: latestSequence, value: latest))
                }
            }
        }
    }

    /// Called by `onChange` with the new value.
    func changed(to value: Value) {
        latestSequence += 1
        latest = value
        currentPacer().send(_Change(sequence: latestSequence, value: value))
    }

    /// Drops the pending value and cancels the running action. Called through ``PacingHandle``.
    func cancel() {
        pacer?.cancel()
        dismissedSequence = latestSequence
    }

    private func currentPacer() -> any _ChangePacer<_Change<Value>> {
        if let pacer {
          return pacer
        }

        guard let configuration else {
            preconditionFailure("update(value:configuration:handle:action:) runs before the first change")
        }

        let gate = gate
        let pacer = makePacer(configuration) { [weak self] change in
            await gate.enter()
            defer { gate.leave() }
            // Take what the action needs and let go of `self` before awaiting it.
            guard !Task.isCancelled, let (action, oldValue) = self?.begin() else {
              return
            }

            await action(oldValue, change.value)

            if !Task.isCancelled {
                self?.finish(change)
            }
        }
        self.pacer = pacer

        return pacer
    }

    private func begin() -> (Action, Value)? {
        guard let action, let handled else {
          return nil
        }
        return (action, handled)
    }

    private func finish(_ change: _Change<Value>) {
        guard change.sequence > handledSequence else {
          return
        }

        handled = change.value
        handledSequence = change.sequence
    }

    // Nonisolated: it's the default argument of the nonisolated `init`, which Swift 6.0 checks.
    nonisolated static func livePacer(
        _ configuration: _PacingConfiguration,
        deliver: @escaping Deliver
    ) -> any _ChangePacer<_Change<Value>> {
        switch configuration.kind {
        case .debounce:
            Debouncer(for: configuration.interval, edges: configuration.edges, action: deliver)
        case .throttle:
            Throttler(for: configuration.interval, edges: configuration.edges, action: deliver)
        }
    }
}

/// Lets one action run at a time, in arrival order. Everything runs on the main actor.
@MainActor
final class _ActionGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init() {}

    func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        // `leave()` hands the gate over to the first waiter without opening it.
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
#endif
