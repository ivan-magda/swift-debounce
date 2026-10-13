#if canImport(SwiftUI)
// The SwiftUI example from README.md, verbatim apart from the `public` access needed by the tests.
import Debounce
import Observation
import SwiftUI

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

public struct SearchView: View {
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
