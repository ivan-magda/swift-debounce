#if canImport(SwiftUI)
import Testing

extension Tag {
    /// Tests that depend on real time. They use wide margins and run one at a time.
    @Tag static var timing: Self
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
func pause(milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

/// Waits until `condition` holds or the timeout passes.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
@MainActor
func eventually(timeout milliseconds: Int = 4_000, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(milliseconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await pause(milliseconds: 10)
    }
    return condition()
}
#endif
