# Using with SwiftUI

Keep the debouncer in an observable model and send values from property observers.

## Search as the user types

SwiftUI can create a view struct many times, and every copy of a debouncer stored in the view would start over. Keep the debouncer in your model instead:

```swift
import Debounce
import Observation
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet { search.send(query) }
    }
    private(set) var results: [String] = []

    @ObservationIgnored
    private lazy var search = Debouncer(for: 0.3) { @MainActor [weak self] (query: String) in
        guard let self else { return }
        results = await SearchService.shared.search(query)
    }
}

struct SearchView: View {
    @State private var model = SearchModel()

    var body: some View {
        NavigationStack {
            List(model.results, id: \.self) { Text($0) }
                .searchable(text: $model.query)
        }
    }
}
```

Mark the debouncer `@ObservationIgnored`: it isn't part of the state your views read. The closure is in a `lazy` property, so it needs an explicit `@MainActor` to update `results`.

## Before iOS 17

With `ObservableObject`, the same pattern works with `@Published` and `@StateObject`:

```swift
@MainActor
final class LegacySearchModel: ObservableObject {
    @Published var query = "" {
        didSet { search.send(query) }
    }
    @Published private(set) var results: [String] = []

    private lazy var search = Debouncer(for: 0.3) { @MainActor [weak self] (query: String) in
        guard let self else { return }
        results = await SearchService.shared.search(query)
    }
}
```

## Throttle frequent updates

For values that change continuously, like a slider or a scroll position, use a ``Throttler`` to limit expensive work while the value changes:

```swift
@ObservationIgnored
private lazy var preview = Throttler(for: 0.1) { @MainActor [weak self] (brightness: Double) in
    await self?.renderPreview(brightness: brightness)
}

var brightness = 0.5 {
    didSet { preview.send(brightness) }
}
```
