#if canImport(SwiftUI)
@testable import DebounceSwiftUI
import Foundation
import Testing

/// What happens to the work when SwiftUI releases the modifier's state, with the real
/// `Debouncer` and real time. These run in `swift test`, so also under Thread Sanitizer; the
/// hosted tests check the same through real views on the iOS Simulator.
@MainActor
@Suite(.serialized, .tags(.timing))
struct ChangePacingStateLifetimeTests {
    @MainActor
    final class Probe {
        var started = false
        var ran = false
        var sawCancellation: Bool?
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    static func configuration(milliseconds: Int) -> _PacingConfiguration {
        _PacingConfiguration(kind: .debounce, interval: .milliseconds(milliseconds), edges: .trailing)
    }

    /// E4: a running action must not keep the state, and with it the debouncer, alive.
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func releasingTheStateCancelsTheRunningAction() async throws {
        let probe = Probe()
        var state: _ChangePacingState<Int>? = _ChangePacingState()
        weak var weakState: _ChangePacingState<Int>?
        weakState = state
        state?.update(value: 0, configuration: Self.configuration(milliseconds: 10), handle: nil) { _, _ in
            probe.started = true
            try? await Task.sleep(for: .seconds(5))
            probe.sawCancellation = Task.isCancelled
        }
        state?.changed(to: 1)
        try #require(await eventually { probe.started })

        state = nil
        #expect(weakState == nil, "the running action doesn't keep the state alive")
        #expect(await eventually { probe.sawCancellation == true })
    }

    /// E5: once the state is released on the main actor, an action that was already waiting to run
    /// on the main actor doesn't start.
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func releasingTheStateStopsAnActionThatWasAboutToStart() async {
        let probe = Probe()
        var state: _ChangePacingState<Int>? = _ChangePacingState()
        state?.update(value: 0, configuration: Self.configuration(milliseconds: 20), handle: nil) { _, _ in
            probe.ran = true
        }
        state?.changed(to: 1)
        // Block the main actor past the deadline: the worker wakes up, takes the value and waits
        // to hop onto the main actor.
        usleep(150_000)
        state = nil
        await pause(milliseconds: 300)
        #expect(!probe.ran)
    }

    /// S10: the same guarantee for `PacingHandle.cancel()`.
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func handleCancelStopsAnActionThatWasAboutToStart() async {
        let probe = Probe()
        let handle = PacingHandle()
        let state = _ChangePacingState<Int>()
        state.update(value: 0, configuration: Self.configuration(milliseconds: 20), handle: handle) { _, _ in
            probe.ran = true
        }
        state.changed(to: 1)
        usleep(150_000)
        handle.cancel()
        await pause(milliseconds: 300)
        #expect(!probe.ran)
    }
}
#endif
