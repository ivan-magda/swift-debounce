# Debouncing value changes in SwiftUI

Run an action once a value settles, or at a steady pace while it changes, right from the view.

## Search once the user stops typing

Add `onChange(of:debounce:)` to the view that owns the value. The action runs once the value has stopped changing for the interval:

```swift
struct SearchView: View {
    @State private var query = ""
    @State private var results: [String] = []

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { Text($0) }
                .searchable(text: $query)
                .onChange(of: query, debounce: .milliseconds(300)) { _, newValue in
                    results = await SearchService.shared.search(newValue)
                }
        }
    }
}
```

The action is async and runs on the main actor, so it can await work and then update the view's state.

If the action only needs the current value, use the variant without parameters and read the value from the view:

```swift
.onChange(of: query, debounce: .milliseconds(300)) {
    results = await SearchService.shared.search(query)
}
```

## Follow a slider without flooding the work

Use `onChange(of:throttle:)` for values that change continuously. With the default edges, the first change runs right away. While the value keeps changing, the latest value runs at most once per interval:

```swift
Slider(value: $brightness)
    .onChange(of: brightness, throttle: .milliseconds(100)) { _, newValue in
        await lamp.setBrightness(newValue)
    }
```

Both modifiers take `edges`, like `Debouncer` and `Throttler`. Pass `.leading` to `onChange(of:debounce:)` to run on the first change of a burst and ignore the rest.

## What old and new values mean

`newValue` is the latest value. `oldValue` is the value the last finished action got, not the previous keystroke. If the user types "S", "Sw" and "Swi" quickly, the action runs once with `oldValue` `""` and `newValue` `"Swi"`. The next run starts from `"Swi"`.

The first `oldValue` is the value the view had when it appeared. A cancelled action doesn't count, so it doesn't change the next `oldValue`.

## How long the work lives

The work is tied to the view's identity, the same way SwiftUI ties `task` to it:

- While the view exists, its work goes on. A search that's already waiting or running finishes even if the user pushes another screen on top.
- New changes arrive the way they do for SwiftUI's own `onChange`: when SwiftUI updates the view. SwiftUI doesn't update a view that a pushed screen covers, so changes made meanwhile arrive when the view is shown again, and only the latest value counts.
- When SwiftUI removes the view, for example when a sheet closes or an `if` branch changes, or when the view gets a new identity through `id(_:)`, the pending value is dropped and the running action is cancelled.

Cancellation is cooperative: a running action stops at its next cancellation check, such as an `await` on a cancellable call or `Task.checkCancellation()`.

Because a pending value is dropped with the view, don't use these modifiers to save a document: a change made just before the view closes would be lost. Save from your model instead.

## Cancel pending work

Keep a ``PacingHandle`` in `@State` and pass it to the modifier when you need to cancel the pending work yourself. For example, when the user presses Return and you search right away:

```swift
@State private var search = PacingHandle()

TextField("Search", text: $query)
    .onChange(of: query, debounce: .milliseconds(300), handle: search) { _, newValue in
        await model.search(newValue)
    }
    .onSubmit {
        search.cancel()
        Task { await model.search(query) }
    }
```

The modifier keeps working after ``PacingHandle/cancel()``: the next change is delivered as usual.

## Things to know

- The action is always the version from the latest view update, so it sees the view's current properties, even if the value itself didn't change.
- The action never runs concurrently with itself. A value that becomes due while the action is still running waits for it to return.
- If the action changes the value it watches, that's a new change, just like with SwiftUI's `onChange`.
- The value must be `Sendable`. If yours isn't, watch a `Sendable` part of it, such as its `id`.
- When SwiftUI removes a view with an animation, it keeps the view's state until the animation ends, and the work can go on until then.
- The interval must be greater than zero and `edges` must not be empty; otherwise the program stops.
