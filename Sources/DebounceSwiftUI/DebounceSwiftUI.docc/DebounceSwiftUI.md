# ``DebounceSwiftUI``

Debounce and throttle value changes in SwiftUI views with one modifier.

## Overview

`DebounceSwiftUI` adds `onChange` variants that wait before they run your action. They work like SwiftUI's `onChange(of:initial:_:)`, take an async action, and run it at the right moment:

```swift
import DebounceSwiftUI

struct SearchView: View {
    @State private var query = ""
    let model: SearchModel

    var body: some View {
        TextField("Search", text: $query)
            .onChange(of: query, debounce: .milliseconds(300)) { oldValue, newValue in
                await model.search(newValue)
            }
    }
}
```

The modifier runs on top of `Debouncer` and `Throttler`, so the action never runs concurrently with itself. The work lives as long as the view: when SwiftUI removes the view, the pending value is dropped and the running action is cancelled.

Importing `DebounceSwiftUI` also imports `Debounce`.

## Topics

### Essentials

- <doc:DebouncingValueChanges>

### Debouncing and throttling changes

- ``SwiftUICore/View/onChange(of:debounce:edges:initial:handle:_:)-6z6vc``
- ``SwiftUICore/View/onChange(of:debounce:edges:initial:handle:_:)-44qjo``
- ``SwiftUICore/View/onChange(of:throttle:edges:initial:handle:_:)-481te``
- ``SwiftUICore/View/onChange(of:throttle:edges:initial:handle:_:)-8sf5e``

### Cancelling pending work

- ``PacingHandle``

### Re-exported from Debounce

- ``Debouncer``
- ``Throttler``
- ``TriggerEdges``
