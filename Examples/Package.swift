// swift-tools-version: 6.0
import PackageDescription

// End-to-end check of the README: the UIKit and SwiftUI examples compile against the package the
// way an app would use it, and the tests drive them on the iOS Simulator.
// Run: xcodebuild test -scheme DebounceExamples-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
let package = Package(
    name: "DebounceExamples",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(name: "swift-debounce", path: ".."),
    ],
    targets: [
        .target(name: "DebounceExamples", dependencies: [
            .product(name: "Debounce", package: "swift-debounce"),
            .product(name: "DebounceSwiftUI", package: "swift-debounce"),
        ]),
        .testTarget(name: "DebounceExamplesTests", dependencies: ["DebounceExamples"]),
    ]
)
