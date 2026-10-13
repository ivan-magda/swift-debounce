# Choosing debounce or throttle

Pick the type and the edges that match how your values arrive.

## Overview

A ``Debouncer`` waits until values stop arriving. While values keep coming, it doesn't run the action at all. A ``Throttler`` runs the action at a steady pace, at most once per interval, while values keep coming.

![A timeline of twelve values in two bursts. The trailing debouncer runs twice, after each burst. The leading debouncer runs on the first value of each burst. The throttler runs six times, once per 100 ms interval.](edges-timeline.svg)

| You want to... | Use |
|---|---|
| Search once the user stops typing | `Debouncer(for: 0.3)` |
| Save a draft once the user pauses | `Debouncer(for: 1)` |
| Run the first tap of a button and ignore quick repeats | `Debouncer(for: 1, edges: .leading)` |
| Update a progress bar at most four times a second | `Throttler(for: 0.25)` |
| Send analytics for scrolling at most once a second | `Throttler(for: 1)` |

## Edges

A burst is a series of values that arrive close together. ``TriggerEdges/leading`` runs the action with the first value of a burst, right away. ``TriggerEdges/trailing`` runs it with the last value, once the burst or the interval is over.

- `Debouncer` uses `.trailing` by default. With `.leading`, it runs the first value and drops the rest of the burst. With both edges, it runs the first value and the last one; a burst of a single value runs once.
- `Throttler` uses both edges by default: a value that arrives while idle runs right away, and the latest value of each interval runs when the interval ends. With `.leading`, values inside an interval are dropped. With `.trailing`, the first value starts an interval and the latest one runs when it ends.

## When you don't need this package

For a single SwiftUI search field, `.task(id:)` with a short sleep is often enough:

```swift
.task(id: query) {
    try? await Task.sleep(for: .milliseconds(300))
    guard !Task.isCancelled else { return }
    await model.search(query)
}
```

Use this package when values come from code that isn't async, when they arrive often, when you need a throttle, or when you need the action to never overlap with itself.
