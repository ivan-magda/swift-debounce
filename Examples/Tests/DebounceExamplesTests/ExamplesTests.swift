import DebounceExamples
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

@MainActor
func eventually(timeout seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
@Suite(.serialized)
struct ExamplesTests {
    #if canImport(UIKit)
    @Test func searchControllerSearchesOnceAfterTyping() async {
        SearchService.shared.reset()
        let controller = SearchViewController(style: .plain)
        controller.loadViewIfNeeded()
        let searchBar = UISearchBar()
        for text in ["S", "Sw", "Swi", "Swif", "Swift"] {
            controller.searchBar(searchBar, textDidChange: text)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await eventually { controller.reloadCount == 1 })
        #expect(SearchService.shared.queries == ["Swift"])
        #expect(controller.results == ["Swift 1", "Swift 2"])
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(controller.reloadCount == 1)
    }

    @Test func closedSearchScreenGetsNoLateCallback() async {
        SearchService.shared.reset()
        do {
            let controller = SearchViewController(style: .plain)
            controller.loadViewIfNeeded()
            controller.searchBar(UISearchBar(), textDidChange: "Swift")
        } // the screen goes away before the debounce interval ends
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(SearchService.shared.queries.isEmpty)
    }

    @Test func payButtonIgnoresDoubleTaps() async {
        let controller = CheckoutViewController()
        controller.payTapped()
        controller.payTapped()
        controller.payTapped()
        #expect(await eventually(timeout: 0.9) { controller.payments == 1 }, "the first tap goes through right away")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.payments == 1)
    }

    @Test func scrollTrackingIsThrottled() async {
        await Analytics.shared.reset()
        let begin = Date()
        let controller = CheckoutViewController()
        let scrollView = UIScrollView()
        scrollView.contentSize = CGSize(width: 100, height: 10_000)
        for y in stride(from: 0.0, through: 500.0, by: 10.0) {
            scrollView.contentOffset.y = y
            controller.scrollViewDidScroll(scrollView)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // With a 1 s interval: the first offset right away, the last one at the end, and at most
        // one more per second of scrolling (a slow CI runner can stretch the 0.5 s loop).
        let scrollSeconds = Date().timeIntervalSince(begin)
        var events: [(name: String, value: Double)] = []
        for _ in 0..<300 {
            events = await Analytics.shared.events
            if events.last?.value == 500 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(events.first?.value == 0)
        #expect(events.last?.value == 500)
        #expect(events.count >= 2 && Double(events.count) <= scrollSeconds + 2)
    }
    #endif

    @Test func swiftUIModelSearchesOnceAfterTyping() async {
        SearchService.shared.reset()
        let model = SearchModel()
        for text in ["S", "Sw", "Swi", "Swif", "Swift"] {
            model.query = text
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await eventually { model.results == ["Swift 1", "Swift 2"] })
        #expect(SearchService.shared.queries == ["Swift"])
    }

    @Test func legacyModelSearchesOnceAfterTyping() async {
        SearchService.shared.reset()
        let model = LegacySearchModel()
        for text in ["S", "Sw", "Swift"] {
            model.query = text
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await eventually { model.results == ["Swift 1", "Swift 2"] })
    }

    @Test func sliderPreviewIsThrottled() async {
        let model = BrightnessModel()
        let begin = Date()
        for step in 0...30 {
            model.brightness = Double(step) / 30
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await eventually { model.renders.last == 1 }, "the final value is rendered")
        let seconds = Date().timeIntervalSince(begin)
        #expect(Double(model.renders.count) <= seconds / 0.1 + 2, "about one render per 100 ms, got \(model.renders.count)")
    }
}
