import Foundation

/// Stand-in for a network search API. Records every query so tests can check how often it ran.
public final class SearchService: Sendable {
    public static let shared = SearchService()
    private let log = Log<String>()

    public func search(_ query: String) async -> [String] {
        log.append(query)
        try? await Task.sleep(nanoseconds: 20_000_000)
        return query.isEmpty ? [] : ["\(query) 1", "\(query) 2"]
    }

    public var queries: [String] { log.values }
    public func reset() { log.reset() }
}

/// Stand-in for an analytics client.
public actor Analytics {
    public static let shared = Analytics()
    public private(set) var events: [(name: String, value: Double)] = []

    public func track(_ name: String, value: Double) {
        events.append((name, value))
    }

    public func reset() { events = [] }
}

final class Log<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ element: Element) { lock.lock(); storage.append(element); lock.unlock() }
    var values: [Element] { lock.lock(); defer { lock.unlock() }; return storage }
    func reset() { lock.lock(); storage = []; lock.unlock() }
}
