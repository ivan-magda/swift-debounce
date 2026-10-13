#if canImport(SwiftUI)
import SwiftUI

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension View {
    /// Runs an action once a value stops changing for a given time.
    ///
    /// Works like `onChange(of:initial:_:)`, but runs the action only after `value` has stopped
    /// changing for `interval`. This is the classic behavior for a search field: wait until the
    /// user stops typing, then search once.
    ///
    /// ```swift
    /// TextField("Search", text: $query)
    ///     .onChange(of: query, debounce: .milliseconds(300)) { oldValue, newValue in
    ///         await model.search(newValue)
    ///     }
    /// ```
    ///
    /// The modifier follows a few rules:
    /// - The action never runs concurrently with itself. A value that becomes due while the action
    ///   is still running waits for it to return. Only the latest such value is kept.
    /// - The action is the version from the latest view update, so it sees the view's current
    ///   properties.
    /// - The work lives as long as the view: when SwiftUI removes the view or its identity
    ///   changes, the pending value is dropped and the running action is cancelled. While the view
    ///   is only covered, for example by a pushed screen, work that already started goes on. New
    ///   changes arrive when SwiftUI updates the view, just like with `onChange(of:initial:_:)`.
    ///
    /// - Parameters:
    ///   - value: The value to watch.
    ///   - interval: How long the value must stop changing before the action runs.
    ///     Must be greater than zero; otherwise the program stops.
    ///   - edges: When to run the action within a burst of changes. Defaults to
    ///     ``TriggerEdges/trailing``. Pass ``TriggerEdges/leading`` to run on the first change
    ///     right away and ignore the rest of the burst. Must not be empty.
    ///   - initial: Whether the action should also run, through the same delay, when the view
    ///     first appears.
    ///   - handle: A handle that lets you cancel the pending work, for example when the user
    ///     submits the search right away.
    ///   - action: The work to run on the main actor. `oldValue` is the value the last finished
    ///     action got (at first, the value when the view appeared); `newValue` is the latest value.
    nonisolated public func onChange<V: Equatable & Sendable>(
        of value: V,
        debounce interval: Duration,
        edges: TriggerEdges = .trailing,
        initial: Bool = false,
        handle: PacingHandle? = nil,
        _ action: @escaping @MainActor (_ oldValue: V, _ newValue: V) async -> Void
    ) -> some View {
        modifier(
            _PacedChangeModifier(
                value: value,
                configuration: _validated(.init(kind: .debounce, interval: interval, edges: edges)),
                initial: initial,
                handle: handle,
                action: action
            )
        )
    }

    /// Runs an action once a value stops changing for a given time.
    ///
    /// The same as ``SwiftUICore/View/onChange(of:debounce:edges:initial:handle:_:)-6z6vc``,
    /// for an action that reads the value it needs from the view:
    ///
    /// ```swift
    /// .onChange(of: query, debounce: .milliseconds(300)) {
    ///     await model.search(query)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - value: The value to watch.
    ///   - interval: How long the value must stop changing before the action runs.
    ///     Must be greater than zero; otherwise the program stops.
    ///   - edges: When to run the action within a burst of changes. Defaults to
    ///     ``TriggerEdges/trailing``. Must not be empty.
    ///   - initial: Whether the action should also run, through the same delay, when the view
    ///     first appears.
    ///   - handle: A handle that lets you cancel the pending work.
    ///   - action: The work to run on the main actor.
    nonisolated public func onChange<V: Equatable & Sendable>(
        of value: V,
        debounce interval: Duration,
        edges: TriggerEdges = .trailing,
        initial: Bool = false,
        handle: PacingHandle? = nil,
        _ action: @escaping @MainActor () async -> Void
    ) -> some View {
        onChange(of: value, debounce: interval, edges: edges, initial: initial, handle: handle) { _, _ in
            await action()
        }
    }

    /// Runs an action at most once per interval while a value keeps changing.
    ///
    /// Works like `onChange(of:initial:_:)`, but runs the action at a steady pace. With the default
    /// edges, the first change runs right away, and while the value keeps changing, the latest
    /// value runs at most once per `interval`. Use it for updates that should follow the user
    /// without flooding the work, such as a slider that controls a lamp:
    ///
    /// ```swift
    /// Slider(value: $brightness)
    ///     .onChange(of: brightness, throttle: .milliseconds(100)) { _, newValue in
    ///         await lamp.setBrightness(newValue)
    ///     }
    /// ```
    ///
    /// The rules are the same as for debouncing: the action never runs concurrently with itself,
    /// it's always the version from the latest view update, and the work lives as long as the
    /// view.
    ///
    /// - Parameters:
    ///   - value: The value to watch.
    ///   - interval: The minimum time between two starts of the action.
    ///     Must be greater than zero; otherwise the program stops.
    ///   - edges: Which values to run. Defaults to both edges: the first change right away, and the
    ///     latest one at the end of each interval. Must not be empty.
    ///   - initial: Whether the action should also run when the view first appears.
    ///   - handle: A handle that lets you cancel the pending work.
    ///   - action: The work to run on the main actor. `oldValue` is the value the last finished
    ///     action got (at first, the value when the view appeared); `newValue` is the latest value.
    nonisolated public func onChange<V: Equatable & Sendable>(
        of value: V,
        throttle interval: Duration,
        edges: TriggerEdges = [.leading, .trailing],
        initial: Bool = false,
        handle: PacingHandle? = nil,
        _ action: @escaping @MainActor (_ oldValue: V, _ newValue: V) async -> Void
    ) -> some View {
        modifier(
            _PacedChangeModifier(
                value: value,
                configuration: _validated(.init(kind: .throttle, interval: interval, edges: edges)),
                initial: initial,
                handle: handle,
                action: action
            )
        )
    }

    /// Runs an action at most once per interval while a value keeps changing.
    ///
    /// The same as ``SwiftUICore/View/onChange(of:throttle:edges:initial:handle:_:)-481te``,
    /// for an action that reads the value it needs from the view.
    ///
    /// - Parameters:
    ///   - value: The value to watch.
    ///   - interval: The minimum time between two starts of the action.
    ///     Must be greater than zero; otherwise the program stops.
    ///   - edges: Which values to run. Defaults to both edges. Must not be empty.
    ///   - initial: Whether the action should also run when the view first appears.
    ///   - handle: A handle that lets you cancel the pending work.
    ///   - action: The work to run on the main actor.
    nonisolated public func onChange<V: Equatable & Sendable>(
        of value: V,
        throttle interval: Duration,
        edges: TriggerEdges = [.leading, .trailing],
        initial: Bool = false,
        handle: PacingHandle? = nil,
        _ action: @escaping @MainActor () async -> Void
    ) -> some View {
        onChange(of: value, throttle: interval, edges: edges, initial: initial, handle: handle) { _, _ in
            await action()
        }
    }
}

/// Checks the arguments where the modifier is written, so a mistake stops the program there and
/// not on the first change.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private func _validated(_ configuration: _PacingConfiguration) -> _PacingConfiguration {
    precondition(configuration.interval > .zero, "The interval must be greater than zero.")
    precondition(!configuration.edges.isEmpty, "Pass at least one edge, or the action would never run.")
    return configuration
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private struct _PacedChangeModifier<V: Equatable & Sendable>: ViewModifier {
    let value: V
    let initial: Bool
    let pacing: _Pacing<V>

    nonisolated init(
        value: V,
        configuration: _PacingConfiguration,
        initial: Bool,
        handle: PacingHandle?,
        action: @escaping @MainActor (V, V) async -> Void
    ) {
        self.value = value
        self.initial = initial
        self.pacing = _Pacing(value: value, configuration: configuration, handle: handle, action: action)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value, initial: initial) { _, newValue in
            pacing.changed(to: newValue)
        }
    }
}

/// Connects the modifier's arguments to its state.
///
/// SwiftUI calls ``update()`` before every evaluation of the modifier's body, so the state always
/// has the latest closure and arguments, even when the value itself didn't change. That way a
/// delayed action never runs a stale closure.
///
/// `update()` isn't main-actor isolated in `DynamicProperty`, but SwiftUI calls it on the main
/// actor; the `@preconcurrency` conformance checks that at run time.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
@MainActor
private struct _Pacing<V: Equatable & Sendable>: @preconcurrency DynamicProperty {
    /// Lives as long as the view's identity. Releasing it cancels the work.
    @State private var state = _ChangePacingState<V>()

    private let value: V
    private let configuration: _PacingConfiguration
    private let handle: PacingHandle?
    private let action: @MainActor (V, V) async -> Void

    // Created by the nonisolated public methods, like SwiftUI's own modifiers.
    nonisolated init(
        value: V,
        configuration: _PacingConfiguration,
        handle: PacingHandle?,
        action: @escaping @MainActor (V, V) async -> Void
    ) {
        self.value = value
        self.configuration = configuration
        self.handle = handle
        self.action = action
    }

    func update() {
        state.update(value: value, configuration: configuration, handle: handle, action: action)
    }

    func changed(to newValue: V) {
        state.changed(to: newValue)
    }
}
#endif
