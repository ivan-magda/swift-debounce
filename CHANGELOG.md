# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-13

### Added

- `DebounceSwiftUI` product with `onChange(of:debounce:)` and `onChange(of:throttle:)` view modifiers. The action is async, runs on the main actor, never overlaps itself, and is always the closure from the latest view update. The work ends when SwiftUI removes the view or its identity changes.
- `PacingHandle` to cancel the pending work of these modifiers, for example when the user submits a search right away.

## [0.1.0] - 2026-10-13

### Added

- `Debouncer` with leading, trailing, or both edges.
- `Throttler` with leading, trailing, or both edges.
- Synchronous, thread-safe `send(_:)`, plus `send()` for `Void`.
- `cancel()`; releasing a debouncer or throttler cancels it too.
- Initializers that take a `Duration` (iOS 16, macOS 13 and later) or a `TimeInterval`.

[Unreleased]: https://github.com/ivan-magda/swift-debounce/compare/0.2.0...HEAD
[0.2.0]: https://github.com/ivan-magda/swift-debounce/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ivan-magda/swift-debounce/releases/tag/0.1.0
