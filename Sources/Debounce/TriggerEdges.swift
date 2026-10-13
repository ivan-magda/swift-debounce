/// The edges of a burst of values on which an action runs.
///
/// A *burst* is a series of values that arrive close together. The leading edge is the first
/// value of a burst, the trailing edge is the moment after the last one.
///
/// ```swift
/// // Run on the first tap right away and ignore the rest of the burst.
/// let tap = Debouncer(for: 0.5, edges: .leading) { pay() }
///
/// // Run on the first value and again with the last value of the burst.
/// let both = Debouncer(for: 0.3, edges: [.leading, .trailing]) { query in search(query) }
/// ```
///
/// - Note: An empty set isn't allowed: it would mean the action never runs.
public struct TriggerEdges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Run the action with the first value of a burst, immediately.
    @inlinable
    public static var leading: TriggerEdges { TriggerEdges(rawValue: 1 << 0) }

    /// Run the action with the last value of a burst, once the burst is over.
    @inlinable
    public static var trailing: TriggerEdges { TriggerEdges(rawValue: 1 << 1) }
}
