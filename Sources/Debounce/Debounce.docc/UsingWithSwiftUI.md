# Using with SwiftUI

Debounce a value in the view with a modifier, or keep the debouncer in an observable model.

## Debounce in the view

The `DebounceSwiftUI` product adds `onChange(of:debounce:)` and `onChange(of:throttle:)`. They're the shortest way to debounce a value that a view owns, and the work ends when the view goes away:

```swift
import DebounceSwiftUI

TextField("Search", text: $query)
    .onChange(of: query, debounce: .milliseconds(300)) { _, newValue in
        results = await SearchService.shared.search(newValue)
    }
```

They need iOS 17, macOS 14, tvOS 17, watchOS 10, or visionOS 1. See the `DebounceSwiftUI` documentation for the full rules.

## Search as the user types, in the model

Keep the debouncer in your model when the logic belongs there: you can test it without a view, and it reacts to every change of the property, not only to the ones made through the UI. Don't store a debouncer in the view itself: SwiftUI can create a view struct many times, and every copy would start over.

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
