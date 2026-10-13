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

    /// S2 and S7 with the real `Debouncer`: when the interval changes while an action that ignores
    /// cancellation still runs, values that become due meanwhile collapse into the latest one.
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func newIntervalWhileAnActionRunsDeliversOnlyTheLatestValue() async throws {
        final class Box {
            var release: CheckedContinuation<Void, Never>?
            var finished: [Int] = []
        }
        let box = Box()
        let state = _ChangePacingState<Int>()
        let action: @MainActor (Int, Int) async -> Void = { _, new in
            if box.release == nil { await withCheckedContinuation { box.release = $0 } }
            box.finished.append(new)
        }
        state.update(value: 0, configuration: Self.configuration(milliseconds: 10), handle: nil, action: action)
        state.changed(to: 1)
        try #require(await eventually { box.release != nil })

        state.update(value: 1, configuration: Self.configuration(milliseconds: 20), handle: nil, action: action)
        state.changed(to: 2)
        await pause(milliseconds: 100) // 2 would be due by now
        state.changed(to: 3)
        await pause(milliseconds: 100) // and so would 3
        box.release?.resume()

        #expect(await eventually { box.finished == [1, 3] })
        await pause(milliseconds: 200)
        #expect(box.finished == [1, 3], "the outdated value never runs")
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
