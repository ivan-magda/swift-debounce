#if canImport(SwiftUI)
@testable import DebounceSwiftUI
import Testing

/// A pacer the test drives by hand: it records what the state sends and lets the test run the
/// action as the real worker would.
final class FakePacer<Value: Sendable>: _ChangePacer, @unchecked Sendable {
    typealias Deliver = @MainActor @Sendable (Value) async -> Void

    let configuration: Any
    let deliver: Deliver
    private(set) var sent: [Value] = []
    private(set) var cancelCount = 0

    init(configuration: Any, deliver: @escaping Deliver) {
        self.configuration = configuration
        self.deliver = deliver
    }

    func send(_ value: Value) { sent.append(value) }
    func cancel() { cancelCount += 1 }
}

/// Builds states whose pacers are fakes, and keeps every pacer it made.
@MainActor
final class FakePacerFactory<Value: Equatable & Sendable> {
    private(set) var pacers: [FakePacer<_Change<Value>>] = []
    var last: FakePacer<_Change<Value>>? { pacers.last }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    func makeState() -> _ChangePacingState<Value> {
        _ChangePacingState { configuration, deliver in
            let pacer = FakePacer<_Change<Value>>(configuration: configuration, deliver: deliver)
            self.pacers.append(pacer)
            return pacer
        }
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
let debounce300 = _PacingConfiguration(kind: .debounce, interval: .milliseconds(300), edges: .trailing)
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
let throttle100 = _PacingConfiguration(kind: .throttle, interval: .milliseconds(100), edges: [.leading, .trailing])

/// Records the arguments of every action call.
@MainActor
final class Calls<Value: Sendable> {
    private(set) var arguments: [(old: Value, new: Value)] = []
    func record(_ old: Value, _ new: Value) { arguments.append((old, new)) }
}

@MainActor
@Suite struct ChangePacingStateTests {
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func pacerIsCreatedOnTheFirstChangeWithTheConfiguration() throws {
        let factory = FakePacerFactory<String>()
        let state = factory.makeState()
        state.update(value: "", configuration: debounce300, handle: nil) { _, _ in }
        #expect(factory.pacers.isEmpty, "no pacer until the value changes")

        state.changed(to: "S")
        let pacer = try #require(factory.last)
        #expect(pacer.configuration as? _PacingConfiguration == debounce300)
        #expect(pacer.sent.map(\.value) == ["S"])
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func oldValueIsTheValueOfTheLastFinishedAction() async throws {
        let factory = FakePacerFactory<String>()
        let state = factory.makeState()
        let calls = Calls<String>()
        state.update(value: "", configuration: debounce300, handle: nil) { calls.record($0, $1) }

        state.changed(to: "S")
        state.changed(to: "Sw")
        let pacer = try #require(factory.last)
        await pacer.deliver(pacer.sent[1])
        state.changed(to: "Swi")
        await pacer.deliver(pacer.sent[2])

        #expect(calls.arguments.map(\.old) == ["", "Sw"], "intermediate values are not old values")
        #expect(calls.arguments.map(\.new) == ["Sw", "Swi"])
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func cancelledActionDoesNotChangeTheOldValue() async throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let calls = Calls<Int>()
        state.update(value: 0, configuration: debounce300, handle: nil) { old, new in
            calls.record(old, new)
            if new == 1 { withUnsafeCurrentTask { $0?.cancel() } } // cancelled while it runs
        }

        state.changed(to: 1)
        let pacer = try #require(factory.last)
        await Task { await pacer.deliver(pacer.sent[0]) }.value
        state.changed(to: 2)
        await pacer.deliver(pacer.sent[1])

        #expect(calls.arguments.map(\.old) == [0, 0])
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func actionDoesNotStartInACancelledTask() async throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let calls = Calls<Int>()
        state.update(value: 0, configuration: debounce300, handle: nil) { calls.record($0, $1) }

        state.changed(to: 1)
        let pacer = try #require(factory.last)
        let task = Task { await pacer.deliver(pacer.sent[0]) }
        task.cancel()
        await task.value

        #expect(calls.arguments.isEmpty)
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func theActionFromTheLatestUpdateRuns() async throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        var ran: [String] = []
        state.update(value: 0, configuration: debounce300, handle: nil) { _, _ in ran.append("first") }
        state.changed(to: 1)
        // The parent updates the view without changing the value, with a new closure.
        state.update(value: 1, configuration: debounce300, handle: nil) { _, _ in ran.append("second") }

        let pacer = try #require(factory.last)
        await pacer.deliver(pacer.sent[0])
        #expect(ran == ["second"])
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func sameConfigurationKeepsThePacer() throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        state.update(value: 0, configuration: debounce300, handle: nil) { _, _ in }
        state.changed(to: 1)
        state.update(value: 1, configuration: debounce300, handle: nil) { _, _ in }
        state.changed(to: 2)

        #expect(factory.pacers.count == 1)
        let pacer = try #require(factory.last)
        #expect(pacer.cancelCount == 0)
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func newConfigurationReplacesThePacerAndKeepsTheUnhandledValue() throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        state.update(value: 0, configuration: debounce300, handle: nil) { _, _ in }
        state.changed(to: 1)
        state.changed(to: 2)
        state.update(value: 2, configuration: throttle100, handle: nil) { _, _ in }

        #expect(factory.pacers.count == 2)
        #expect(factory.pacers[0].cancelCount == 1)
        #expect(factory.pacers[1].configuration as? _PacingConfiguration == throttle100)
        #expect(factory.pacers[1].sent.map(\.value) == [2], "the latest change isn't lost")
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func newConfigurationDoesNotRepeatAHandledValue() async throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        state.update(value: 0, configuration: debounce300, handle: nil) { _, _ in }
        state.changed(to: 1)
        let first = try #require(factory.last)
        await first.deliver(first.sent[0])
        state.update(value: 1, configuration: throttle100, handle: nil) { _, _ in }

        #expect(first.cancelCount == 1)
        #expect(factory.pacers.count == 1, "nothing to deliver, so the new pacer waits for a change")
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func newConfigurationBeforeAnyChangeCreatesNoPacer() {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        state.update(value: 0, configuration: debounce300, handle: nil) { _, _ in }
        state.update(value: 0, configuration: throttle100, handle: nil) { _, _ in }
        #expect(factory.pacers.isEmpty)
    }

    /// A new pacer only gets the latest change, and only once the old pacer's action returned, even
    /// if that action ignores cancellation. Otherwise an outdated value would run after it, and a
    /// throttle's window would start too early.
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func newPacerWaitsForTheActionOfTheOldOne() async throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let action: @MainActor (Int, Int) async -> Void = { _, new in
            events.append("start \(new)")
            // The first action ignores cancellation and runs until the test releases it.
            if release == nil { await withCheckedContinuation { release = $0 } }
            events.append("end \(new)")
        }
        state.update(value: 0, configuration: debounce300, handle: nil, action: action)
        state.changed(to: 1)
        let old = try #require(factory.last)
        let oldAction = Task { await old.deliver(old.sent[0]) }
        while release == nil { await Task.yield() }

        state.update(value: 1, configuration: throttle100, handle: nil, action: action)
        state.changed(to: 2)
        state.changed(to: 3)
        #expect(old.cancelCount == 1)
        #expect(factory.pacers.count == 1, "no new pacer while the old action runs")

        release?.resume()
        await oldAction.value
        let new = try #require(factory.pacers.last)
        #expect(new !== old)
        #expect(new.sent.map(\.value) == [3], "only the latest change goes to the new pacer")

        await new.deliver(new.sent[0])
        #expect(events == ["start 1", "end 1", "start 3", "end 3"])
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func changeCancelledWhileWaitingForTheOldActionIsNotDelivered() async throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let handle = PacingHandle()
        var release: CheckedContinuation<Void, Never>?
        let action: @MainActor (Int, Int) async -> Void = { _, _ in
            if release == nil { await withCheckedContinuation { release = $0 } }
        }
        state.update(value: 0, configuration: debounce300, handle: handle, action: action)
        state.changed(to: 1)
        let old = try #require(factory.last)
        let oldAction = Task { await old.deliver(old.sent[0]) }
        while release == nil { await Task.yield() }
        state.update(value: 1, configuration: throttle100, handle: handle, action: action)
        state.changed(to: 2)

        handle.cancel()
        release?.resume()
        await oldAction.value

        #expect(factory.pacers.count == 1, "the cancelled change isn't sent to a new pacer")
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func sameValueAsTheHandledOneIsStillDelivered() async throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let calls = Calls<Int>()
        state.update(value: 0, configuration: debounce300, handle: nil) { calls.record($0, $1) }
        state.changed(to: 1)
        state.changed(to: 0)
        let pacer = try #require(factory.last)
        await pacer.deliver(pacer.sent[1])
        #expect(calls.arguments.map(\.old) == [0])
        #expect(calls.arguments.map(\.new) == [0])
    }

    /// The real pacer's action points back at the state; that reference must not keep it alive.
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test(arguments: [debounce300, throttle100])
    func releasingTheStateReleasesTheRealPacer(configuration: _PacingConfiguration) {
        weak var weakState: _ChangePacingState<Int>?
        weak var weakPacer: AnyObject?
        do {
            var pacer: AnyObject?
            let state = _ChangePacingState<Int> { configuration, deliver in
                let made = _ChangePacingState<Int>.livePacer(configuration, deliver: deliver)
                pacer = made
                return made
            }
            state.update(value: 0, configuration: configuration, handle: nil) { _, _ in }
            state.changed(to: 1)
            weakState = state
            weakPacer = pacer
            #expect(weakPacer != nil)
        }
        #expect(weakState == nil)
        #expect(weakPacer == nil)
    }
}
#endif
