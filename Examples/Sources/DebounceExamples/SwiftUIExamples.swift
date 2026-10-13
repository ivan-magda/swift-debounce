#if canImport(SwiftUI)
// The SwiftUI examples from README.md and the documentation, verbatim apart from the `public`
// access needed by the tests and the names that would otherwise clash.
import DebounceSwiftUI
import Observation
import SwiftUI

// README: debounce a value right where the view uses it.
public struct SearchView: View {
    @State private var query = ""
    @State private var results: [String] = []

    public init() {}

    public var body: some View {
        NavigationStack {
            List(results, id: \.self) { Text($0) }
                .searchable(text: $query)
                .onChange(of: query, debounce: .milliseconds(300)) { _, newValue in
                    results = await SearchService.shared.search(newValue)
                }
        }
    }
}

// Adapted from the DebounceSwiftUI documentation: on Return, search right away and cancel the
// pending search.
public struct SubmittingSearchView: View {
    @State private var query = ""
    @State private var search = PacingHandle()
    let model: SearchModel

    public init(model: SearchModel) {
        self.model = model
    }

    public var body: some View {
        TextField("Search", text: $query)
            .onChange(of: query, debounce: .milliseconds(300), handle: search) { _, newValue in
                model.query = newValue
            }
            .onSubmit {
                search.cancel()
                model.query = query
            }
    }
}

// README: a slider that follows the user without flooding the work.
public struct BrightnessSlider: View {
    @State private var brightness = 0.5
    let lamp: Lamp

    public init(lamp: Lamp) {
        self.lamp = lamp
    }

    public var body: some View {
        Slider(value: $brightness)
            .onChange(of: brightness, throttle: .milliseconds(100)) { _, newValue in
                await lamp.setBrightness(newValue)
            }
    }
}

public actor Lamp {
    public private(set) var brightness = 0.0
    public init() {}
    public func setBrightness(_ value: Double) { brightness = value }
}

@MainActor
@Observable
public final class SearchModel {
    public var query = "" {
        didSet { search.send(query) }
    }
    public private(set) var results: [String] = []

    @ObservationIgnored
    private lazy var search = Debouncer(for: 0.3) { @MainActor [weak self] (query: String) in
        guard let self else { return }
        results = await SearchService.shared.search(query)
    }

    public init() {}
}

// From the "Using with SwiftUI" guide in the documentation.
@MainActor
public final class LegacySearchModel: ObservableObject {
    @Published public var query = "" {
        didSet { search.send(query) }
    }
    @Published public private(set) var results: [String] = []

    private lazy var search = Debouncer(for: 0.3) { @MainActor [weak self] (query: String) in
        guard let self else { return }
        results = await SearchService.shared.search(query)
    }

    public init() {}
}

@MainActor
@Observable
public final class BrightnessModel {
    @ObservationIgnored
    private lazy var preview = Throttler(for: 0.1) { @MainActor [weak self] (brightness: Double) in
        await self?.renderPreview(brightness: brightness)
    }

    public var brightness = 0.5 {
        didSet { preview.send(brightness) }
    }

    public private(set) var renders: [Double] = []

    public init() {}

    private func renderPreview(brightness: Double) async {
        renders.append(brightness)
    }
}

// README: keep the debouncer in the model when the logic belongs there.
public struct ModelSearchView: View {
    @State private var model = SearchModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            List(model.results, id: \.self) { Text($0) }
                .searchable(text: $model.query)
        }
    }
}
#endif
