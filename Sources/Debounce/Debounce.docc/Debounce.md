# ``Debounce``

Debounce and throttle for Swift Concurrency, with a synchronous `send` you can call from any thread.

## Overview

Call `send(_:)` as often as you like, without `await`, and your async action runs at the right moment. A ``Debouncer`` waits until values stop arriving. A ``Throttler`` runs the action at most once per interval while values keep coming.

```swift
import Debounce

let search = Debouncer(for: 0.3) { (query: String) in
    await searchService.search(query)
}

search.send("S")
search.send("Sw")
search.send("Swift") // only "Swift" is searched, 0.3 s later
```

Both types run your action one at a time, never concurrently with itself, and both drop pending values when you cancel them or release them. `send` costs about 15 ns, so you can call it for every scroll event or sensor reading.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ChoosingDebounceOrThrottle>

### Debouncing and throttling

- ``Debouncer``
- ``Throttler``
- ``TriggerEdges``

### Using the package in an app

- <doc:UsingWithUIKit>
- <doc:UsingWithSwiftUI>

### Behavior and design

- <doc:HowItWorks>
