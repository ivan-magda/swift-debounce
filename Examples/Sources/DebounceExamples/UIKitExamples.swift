#if canImport(UIKit)
// The UIKit examples from README.md, verbatim apart from the `public` access needed by the tests.
import Debounce
import UIKit

public final class SearchViewController: UITableViewController, UISearchBarDelegate {
    public private(set) var results: [String] = []
    public private(set) var reloadCount = 0

    // A closure in a lazy property doesn't inherit the main actor, so mark it @MainActor.
    private lazy var search = Debouncer(for: 0.3) { @MainActor [weak self] (query: String) in
        await self?.showResults(for: query)
    }

    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        search.send(searchText)
    }

    private func showResults(for query: String) async {
        results = await SearchService.shared.search(query)
        tableView.reloadData()
        reloadCount += 1
    }
}

public final class CheckoutViewController: UIViewController, UIScrollViewDelegate {
    public private(set) var payments = 0

    private lazy var pay = Debouncer(for: 1, edges: .leading) { @MainActor [weak self] in
        self?.submitPayment()
    }

    private let trackScroll = Throttler(for: 1) { (offset: Double) in
        await Analytics.shared.track("checkout_scroll", value: offset)
    }

    @objc public func payTapped() {
        pay.send()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        trackScroll.send(scrollView.contentOffset.y)
    }

    private func submitPayment() {
        MainActor.assertIsolated()
        payments += 1
    }
}
#endif
