# Getting started

Add the package, create a debouncer, and send it values.

## Add the package

In Xcode, choose **File > Add Package Dependencies** and enter `https://github.com/ivan-magda/swift-debounce`. In a `Package.swift`, add the dependency and the `Debounce` product:

```swift
dependencies: [
    .package(url: "https://github.com/ivan-magda/swift-debounce", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Debounce", package: "swift-debounce"),
    ]),
]
```

## Create a debouncer

Pass the quiet time and the action. On iOS 16 and macOS 13 or later you can pass a `Duration`; on older systems, pass seconds:

```swift
let save = Debouncer(for: .seconds(1)) { (text: String) in
    await draftStore.save(text)
}

let saveOnOlderSystems = Debouncer(for: 1.0) { (text: String) in
    await draftStore.save(text)
}
```

Then send values whenever they change. `send(_:)` returns right away:

```swift
func textViewDidChange(_ textView: UITextView) {
    save.send(textView.text)
}
```

For signals without a value, use `Void`:

```swift
let reload = Debouncer(for: 0.5) { await feed.reload() }
reload.send()
```

## Choose where the action runs

The action runs on its own actor. A closure you create inside a `@MainActor` method inherits the main actor, the same way `Task { }` does. A closure in a stored or `lazy` property doesn't, so mark it yourself:

```swift
@MainActor
final class EditorViewController: UIViewController {
    private lazy var save = Debouncer(for: 1.0) { @MainActor [weak self] (text: String) in
        self?.statusLabel.text = "Saving..."
        await DraftStore.shared.save(text)
        self?.statusLabel.text = "Saved"
    }
}
```

A closure with no actor runs off the main thread. The waiting itself never blocks the main thread.

## Cancel

Call ``Debouncer/cancel()`` to drop the pending value and cancel the running action. Releasing the debouncer does the same, so a closed screen never gets a late callback. You can keep using a debouncer after cancelling it.
