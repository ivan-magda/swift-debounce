#if canImport(SwiftUI)
/// Cancels the work of the `onChange` modifiers you pass it to.
///
/// Keep a handle in `@State` and pass it to `onChange(of:debounce:handle:_:)` or
/// `onChange(of:throttle:handle:_:)`. Call ``cancel()`` when the pending work is no longer
/// needed. For example, when the user presses Return and you search right away:
///
/// ```swift
/// struct SearchView: View {
///     @State private var query = ""
///     @State private var search = PacingHandle()
///     let model: SearchModel
///
///     var body: some View {
///         TextField("Search", text: $query)
///             .onChange(of: query, debounce: .milliseconds(300), handle: search) { _, newValue in
///                 await model.search(newValue)
///             }
///             .onSubmit {
///                 search.cancel()
///                 Task { await model.search(query) }
///             }
///     }
/// }
/// ```
///
/// You can pass one handle to several modifiers; ``cancel()`` cancels all of them. The handle
/// doesn't keep the modifiers or their views alive.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
@MainActor
public final class PacingHandle {
    private var states: [WeakState] = []

    /// Creates a handle that isn't attached to any modifier yet.
    nonisolated public init() {}

    /// Drops the pending value and cancels the running action of every modifier that uses this
    /// handle.
    ///
    /// The modifiers keep working: the next change of the value is delivered as usual. A cancelled
    /// action doesn't count as handled, so it doesn't change the next `oldValue`.
    ///
    /// Cancellation is cooperative: a running action stops at its next cancellation check. Until
    /// then, it can still be running when you start other work.
    public func cancel() {
        states.removeAll { $0.state == nil }
        for entry in states {
            entry.state?.cancel()
        }
    }

    func attach(_ state: some _PacingHandleClient) {
        states.removeAll { $0.state == nil || $0.state === state }
        states.append(WeakState(state: state))
    }

    func detach(_ state: some _PacingHandleClient) {
        states.removeAll { $0.state == nil || $0.state === state }
    }

    private struct WeakState {
        weak var state: (any _PacingHandleClient)?
    }
}

/// A modifier state that a ``PacingHandle`` can cancel.
@MainActor
protocol _PacingHandleClient: AnyObject {
    func cancel()
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension _ChangePacingState: _PacingHandleClient {}
#endif
