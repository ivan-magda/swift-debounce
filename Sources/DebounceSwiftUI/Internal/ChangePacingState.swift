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
    /// True while the user's action runs. Actions never overlap, so at most one runs at a time.
    private var isActionRunning = false
    /// The configuration changed while an action of the old pacer was still running. Until it
    /// returns, changes are only recorded: the new pacer gets just the latest one afterwards, so
    /// its timing starts then and an outdated value never runs after the old action.
    private var isWaitingForThePreviousAction = false

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

                if isActionRunning {
                    isWaitingForThePreviousAction = true
                } else {
                    sendUnhandledChange()
                }
            }
        }
    }

    /// Called by `onChange` with the new value.
    func changed(to value: Value) {
        latestSequence += 1
        latest = value

        guard !isWaitingForThePreviousAction else {
          return
        }

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

        let pacer = makePacer(configuration) { [weak self] change in
            // Take what the action needs and let go of `self` before awaiting it.
            guard !Task.isCancelled, let (action, oldValue) = self?.begin() else {
              return
            }

            await action(oldValue, change.value)

            self?.end(change, finished: !Task.isCancelled)
        }
        self.pacer = pacer

        return pacer
    }

    private func begin() -> (Action, Value)? {
        guard let action, let handled else {
          return nil
        }

        isActionRunning = true

        return (action, handled)
    }

    private func end(_ change: _Change<Value>, finished: Bool) {
        isActionRunning = false

        if finished, change.sequence > handledSequence {
            handled = change.value
            handledSequence = change.sequence
        }

        if isWaitingForThePreviousAction {
            isWaitingForThePreviousAction = false
            sendUnhandledChange()
        }
    }

    /// Sends the latest change to the current pacer, unless it was handled or cancelled already.
    private func sendUnhandledChange() {
        guard latestSequence > max(handledSequence, dismissedSequence), let latest else {
          return
        }

        currentPacer().send(_Change(sequence: latestSequence, value: latest))
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
#endif
