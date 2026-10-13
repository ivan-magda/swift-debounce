#if canImport(UIKit) && !os(watchOS)
import DebounceSwiftUI
import SwiftUI
import Testing
import UIKit

/// End-to-end tests: real SwiftUI views in a real window, real `Debouncer` and `Throttler`, real
/// time. They run on the iOS Simulator (`xcodebuild test`); `swift test` on macOS can't drive
/// SwiftUI updates.
///
/// Intervals are 1 s with timeouts of several seconds: CI runners can stall the main actor for
/// hundreds of milliseconds, and a stall must not split a burst or let a delayed action run early.

@available(iOS 17, tvOS 17, visionOS 1, *)
@Observable @MainActor
final class Screen {
    var query = ""
    var showsSearch = true
    var searchID = 0
    var prefix = "v1"
    var path: [Int] = []
    var events: [String] = []
}

@available(iOS 17, tvOS 17, visionOS 1, *)
struct SearchField: View {
    let screen: Screen
    let prefix: String
    var interval: Duration = .seconds(1)
    var initial = false
    var handle: PacingHandle?
    var slowAction = false

    var body: some View {
        Text(screen.query)
            .onChange(of: screen.query, debounce: interval, initial: initial, handle: handle) { old, new in
                screen.events.append("\(prefix) \(old)->\(new)")
                if slowAction {
                    try? await Task.sleep(for: .seconds(5))
                    screen.events.append(Task.isCancelled ? "cancelled" : "finished")
                }
            }
    }
}

@available(iOS 17, tvOS 17, visionOS 1, *)
struct Root: View {
    let screen: Screen
    var interval: Duration = .seconds(1)
    var initial = false
    var handle: PacingHandle?
    var slowAction = false

    var body: some View {
        NavigationStack(path: Binding(get: { screen.path }, set: { screen.path = $0 })) {
            Group {
                if screen.showsSearch {
                    SearchField(
                        screen: screen, prefix: screen.prefix, interval: interval,
                        initial: initial, handle: handle, slowAction: slowAction
                    )
                    .id(screen.searchID)
                }
            }
            .navigationDestination(for: Int.self) { Text("Detail \($0)") }
        }
    }
}

/// Puts a view on screen and keeps it there until `close()`.
@MainActor
final class Host {
    private let window: UIWindow

    init(_ view: some View) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
@Suite(.serialized, .tags(.timing))
struct HostedOnChangeTests {
    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func burstOfChangesRunsTheActionOnceWithTheLatestValue() async {
        let screen = Screen()
        let host = Host(Root(screen: screen))
        defer { host.close() }
        await pause(milliseconds: 100)

        for query in ["S", "Sw", "Swi", "Swift"] {
            screen.query = query
            await pause(milliseconds: 20)
        }
        #expect(await eventually { screen.events == ["v1 ->Swift"] })
        await pause(milliseconds: 1_500)
        #expect(screen.events == ["v1 ->Swift"], "nothing else runs")

        screen.query = "SwiftUI"
        #expect(await eventually { screen.events.last == "v1 Swift->SwiftUI" }, "oldValue is the last handled value")
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func removingTheViewDropsThePendingValue() async {
        let screen = Screen()
        let host = Host(Root(screen: screen))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.query = "S"
        await pause(milliseconds: 50)
        screen.showsSearch = false
        await pause(milliseconds: 2_000)
        #expect(screen.events.isEmpty)
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func removingTheViewCancelsTheRunningAction() async throws {
        let screen = Screen()
        let host = Host(Root(screen: screen, interval: .milliseconds(50), slowAction: true))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.query = "S"
        try #require(await eventually { screen.events == ["v1 ->S"] })
        screen.showsSearch = false
        #expect(await eventually(timeout: 2_000) { screen.events == ["v1 ->S", "cancelled"] })
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func newIdentityDropsThePendingValueAndStartsOver() async {
        let screen = Screen()
        let host = Host(Root(screen: screen))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.query = "S"
        await pause(milliseconds: 50)
        screen.searchID += 1
        await pause(milliseconds: 2_000)
        #expect(screen.events.isEmpty, "the old identity's pending value is dropped")

        screen.query = "Sw"
        #expect(await eventually { screen.events == ["v1 S->Sw"] }, "the new identity starts from the current value")
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func workGoesOnWhileAnotherScreenIsPushedOnTop() async {
        let screen = Screen()
        let host = Host(Root(screen: screen))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.query = "S"
        screen.path.append(1)
        #expect(await eventually { screen.events == ["v1 ->S"] })
    }

    /// SwiftUI doesn't update a view covered by a pushed screen, so its `onChange` (and ours, which
    /// is built on it) sees changes made meanwhile only when the view is shown again. Whether
    /// anything arrives while covered is SwiftUI's call; the test only checks the package's part:
    /// the latest value is delivered once the view is back.
    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func changesWhileCoveredArriveWhenTheViewIsShownAgain() async {
        let screen = Screen()
        let host = Host(Root(screen: screen))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.path.append(1)
        await pause(milliseconds: 1_500) // let the push finish
        screen.query = "y"
        await pause(milliseconds: 20)
        screen.query = "yz"
        await pause(milliseconds: 500)
        screen.path.removeAll()
        #expect(await eventually { screen.events.last == "v1 ->yz" }, "the latest value arrives after the pop")
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func actionUsesTheClosureFromTheLatestUpdate() async {
        let screen = Screen()
        let host = Host(Root(screen: screen))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.query = "S"
        await pause(milliseconds: 50)
        screen.prefix = "v2" // the parent re-renders the field with a new closure; the value stays
        #expect(await eventually { screen.events == ["v2 ->S"] })
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func handleCancelsThePendingValue() async {
        let screen = Screen()
        let handle = PacingHandle()
        let host = Host(Root(screen: screen, handle: handle))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.query = "S"
        await pause(milliseconds: 50)
        handle.cancel()
        await pause(milliseconds: 2_000)
        #expect(screen.events.isEmpty)

        screen.query = "Sw"
        #expect(await eventually { screen.events == ["v1 ->Sw"] }, "the modifier keeps working")
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func initialRunsWhenTheViewAppears() async {
        let screen = Screen()
        screen.query = "Swift"
        let host = Host(Root(screen: screen, initial: true))
        defer { host.close() }
        #expect(await eventually { screen.events == ["v1 Swift->Swift"] })
    }

    @available(iOS 17, tvOS 17, visionOS 1, *)
    @Test func throttleRunsTheFirstChangeRightAwayAndTheLatestAtTheEnd() async {
        let screen = Screen()
        struct Slider: View {
            let screen: Screen
            var body: some View {
                Text(screen.query)
                    .onChange(of: screen.query, throttle: .seconds(1)) { _, new in
                        screen.events.append(new)
                    }
            }
        }
        let host = Host(Slider(screen: screen))
        defer { host.close() }
        await pause(milliseconds: 100)

        screen.query = "1"
        // Well before the 1 s interval: a trailing-only throttle would wait for it.
        #expect(await eventually(timeout: 800) { screen.events == ["1"] }, "the leading edge runs right away")
        // Two separate changes inside the interval: only the later one runs, at its end.
        screen.query = "2"
        await pause(milliseconds: 100)
        screen.query = "3"
        #expect(await eventually { screen.events == ["1", "3"] }, "the latest value runs at the end of the interval")
        await pause(milliseconds: 1_500)
        #expect(screen.events == ["1", "3"], "the skipped value never runs")
    }
}
#endif
