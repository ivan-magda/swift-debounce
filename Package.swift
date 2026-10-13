// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-debounce",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Debounce", targets: ["Debounce"]),
        .library(name: "DebounceSwiftUI", targets: ["DebounceSwiftUI"]),
    ],
    targets: [
        .target(name: "Debounce"),
        .target(name: "DebounceSwiftUI", dependencies: ["Debounce"]),
        .testTarget(name: "DebounceTests", dependencies: ["Debounce"]),
        .testTarget(name: "DebounceE2ETests", dependencies: ["Debounce"]),
        .testTarget(name: "DebounceSwiftUITests", dependencies: ["DebounceSwiftUI"]),
    ]
)
