# Using with UIKit

Debounce a search bar, protect a button from double taps, and throttle scroll events.

## Search as the user types

Store the debouncer in a `lazy` property. A closure in a property initializer doesn't inherit the main actor, so mark it `@MainActor`; the action can then update the UI directly:

```swift
import Debounce
import UIKit

final class SearchViewController: UITableViewController, UISearchBarDelegate {
    private var results: [String] = []

    private lazy var search = Debouncer(for: 0.3) { @MainActor [weak self] (query: String) in
        await self?.showResults(for: query)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        search.send(searchText)
    }

    private func showResults(for query: String) async {
        results = await SearchService.shared.search(query)
        tableView.reloadData()
    }
}
```

Capture `self` weakly. The debouncer belongs to the view controller, so a strong capture would keep the controller alive.

When the user leaves the screen, the view controller and its debouncer go away, and the pending search is dropped.

## Protect a button from double taps

Use the leading edge: the first tap runs right away, and further taps are ignored until there has been no tap for a full second:

```swift
private lazy var pay = Debouncer(for: 1, edges: .leading) { @MainActor [weak self] in
    self?.submitPayment()
}

@objc private func payTapped() {
    pay.send()
}
```

A user who keeps tapping every half second never gets a second payment, because each tap extends the quiet period. If a tap should go through at most once per second, however often the user taps, use `Throttler(for: 1, edges: .leading)` instead.

## Throttle scroll events

`scrollViewDidScroll(_:)` fires on every frame. A throttler turns that into at most one call per interval, and still delivers the final position:

```swift
private let trackScroll = Throttler(for: 1) { (offset: Double) in
    await Analytics.shared.track("checkout_scroll", value: offset)
}

func scrollViewDidScroll(_ scrollView: UIScrollView) {
    trackScroll.send(scrollView.contentOffset.y)
}
```

This closure has no actor, so the tracking runs off the main thread.
