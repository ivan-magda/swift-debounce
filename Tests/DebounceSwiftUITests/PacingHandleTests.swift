#if canImport(SwiftUI)
@testable import DebounceSwiftUI
import Testing

@MainActor
@Suite struct PacingHandleTests {
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func cancelCancelsThePacer() throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let handle = PacingHandle()
        state.update(value: 0, configuration: debounce300, handle: handle) { _, _ in }
        state.changed(to: 1)

        handle.cancel()
        let pacer = try #require(factory.last)
        #expect(pacer.cancelCount == 1)
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func cancelBeforeTheFirstChangeDoesNothing() {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let handle = PacingHandle()
        state.update(value: 0, configuration: debounce300, handle: handle) { _, _ in }

        handle.cancel()
        #expect(factory.pacers.isEmpty)
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func modifierKeepsWorkingAfterCancel() throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let handle = PacingHandle()
        state.update(value: 0, configuration: debounce300, handle: handle) { _, _ in }
        state.changed(to: 1)
        handle.cancel()
        state.changed(to: 2)

        let pacer = try #require(factory.last)
        #expect(pacer.sent.map(\.value) == [1, 2])
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func cancelledValueIsNotDeliveredAgainWhenTheConfigurationChanges() {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let handle = PacingHandle()
        state.update(value: 0, configuration: debounce300, handle: handle) { _, _ in }
        state.changed(to: 1)
        handle.cancel()
        state.update(value: 1, configuration: throttle100, handle: handle) { _, _ in }

        #expect(factory.pacers.count == 1, "the user cancelled the change; the new pacer has nothing to do")
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func oneHandleCancelsEveryModifierUsingIt() throws {
        let first = FakePacerFactory<Int>()
        let second = FakePacerFactory<String>()
        let firstState = first.makeState()
        let secondState = second.makeState()
        let handle = PacingHandle()
        firstState.update(value: 0, configuration: debounce300, handle: handle) { _, _ in }
        secondState.update(value: "", configuration: throttle100, handle: handle) { _, _ in }
        firstState.changed(to: 1)
        secondState.changed(to: "a")

        handle.cancel()
        #expect(try #require(first.last).cancelCount == 1)
        #expect(try #require(second.last).cancelCount == 1)
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func passingAnotherHandleOrNilDetachesTheModifier() throws {
        let factory = FakePacerFactory<Int>()
        let state = factory.makeState()
        let old = PacingHandle()
        let new = PacingHandle()
        state.update(value: 0, configuration: debounce300, handle: old) { _, _ in }
        state.changed(to: 1)
        state.update(value: 1, configuration: debounce300, handle: new) { _, _ in }

        old.cancel()
        let pacer = try #require(factory.last)
        #expect(pacer.cancelCount == 0, "the modifier no longer uses the old handle")
        new.cancel()
        #expect(pacer.cancelCount == 1)

        state.update(value: 1, configuration: debounce300, handle: nil) { _, _ in }
        new.cancel()
        #expect(pacer.cancelCount == 1, "nil detaches the modifier")
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
    @Test func handleDoesNotKeepTheModifierAlive() {
        let handle = PacingHandle()
        weak var weakState: _ChangePacingState<Int>?
        do {
            let state = FakePacerFactory<Int>().makeState()
            state.update(value: 0, configuration: debounce300, handle: handle) { _, _ in }
            weakState = state
        }
        #expect(weakState == nil)
        handle.cancel() // must not crash with a released modifier
    }
}
#endif
