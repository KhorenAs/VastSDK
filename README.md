# VASTSDK

A native VAST 4.3 linear-video ad SDK. No Google IMA, no VPAID, no WebView.

| Platform | Status |
|---|---|
| [Apple](Apple/) — iOS · tvOS · macOS | Implemented. 229 tests. |
| [Android](Android/) | Not started. |
| [Web](Web/) | Not started. |

Each platform is a self-contained project with its own build and its own tests.
They share the specification, the test fixtures and the behavioural decisions —
not code.

[GO-LIVE.md](GO-LIVE.md) lists what the Apple SDK still needs before it serves
real ads, ordered by what blocks the road rather than by effort.

## Apple

```swift
.package(url: "https://github.com/KhorenAs/VastSDK.git", from: "1.0.0")
```

Then depend on `VASTKit` (player and ad UI) or `VASTCore` alone (parsing,
wrapper chains, pod scheduling and tracking, with no player at all).

```swift
let session = VASTAdSession(player: myPlayer)

try await session.load(tag: adTagURL)   // follows Wrapper chains
await session.play()                    // plays the pod, reports tracking
```

See [Apple/README.md](Apple/README.md) for the rest of the API, what the SDK
covers, and the design decisions worth knowing before using it.

Working on the SDK itself:

```bash
swift build                 # or: cd Apple && swift build
swift test                  # 229 tests
```

The manifest at the repository root and the one in `Apple/` describe the same
targets. The root one exists because SwiftPM resolves a dependency URL by
looking for `Package.swift` at the root; the one in `Apple/` is what
`Examples/VASTDemo.xcodeproj` references as a local package.

## License

MIT — see [LICENSE](LICENSE).

Test fixtures under `Apple/Tests/VASTCoreTests/Fixtures/` derive from the IAB
sample tags shipped with [dailymotion/vast-client-js](https://github.com/dailymotion/vast-client-js)
(MIT). `Apple/Reference/` holds the IAB VAST XSD schemas.
