// swift-tools-version: 6.0
import PackageDescription

// A separate package on purpose: people who depend on swift-debounce never resolve or build it.
// It compares the real Debouncer and Throttler against reference implementations.
let package = Package(
    name: "Benchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "swift-debounce", path: ".."),
    ],
    targets: [
        // Enable cross-module optimization for References.
        // It does not guarantee specialization: the Swift 6.4 build still called
        // generic emit methods for both reference debouncers. See README.md.
        .target(
            name: "References",
            dependencies: [.product(name: "Debounce", package: "swift-debounce")],
            swiftSettings: [.unsafeFlags(["-cross-module-optimization"])]
        ),
        .executableTarget(name: "Scenarios", dependencies: ["References", .product(name: "Debounce", package: "swift-debounce")]),
        .executableTarget(name: "Locks", dependencies: ["References", .product(name: "Debounce", package: "swift-debounce")]),
        .executableTarget(name: "Storage", dependencies: ["References"]),
        .executableTarget(name: "Latency", dependencies: ["References", .product(name: "Debounce", package: "swift-debounce")]),
        .executableTarget(name: "Throttling", dependencies: [.product(name: "Debounce", package: "swift-debounce")]),
    ]
)
