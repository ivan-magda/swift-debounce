import Debounce

// Lets the benchmarks drive the real package types through the same interface as the references.
extension Debouncer: DebounceUnderTest {
    @inlinable public func emit(value: Value) { send(value) }
}
