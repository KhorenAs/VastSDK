# VASTSDK

A native VAST 4.3 linear-video ad SDK. No Google IMA, no VPAID, no WebView.

| Platform | Status |
|---|---|
| [Apple](Apple/) — iOS · tvOS · macOS | Implemented. 111 tests. |
| [Android](Android/) | Not started. |
| [Web](Web/) | Not started. |

Each platform is a self-contained project with its own build and its own tests.
They share the specification, the test fixtures and the behavioural decisions —
not code.

## Apple

```bash
cd Apple
swift build
swift test
```

See [Apple/README.md](Apple/README.md) for the API, what the SDK covers, and the
two design decisions worth knowing before using it.

## License

MIT — see [LICENSE](LICENSE).

Test fixtures under `Apple/Tests/VASTCoreTests/Fixtures/` derive from the IAB
sample tags shipped with [dailymotion/vast-client-js](https://github.com/dailymotion/vast-client-js)
(MIT). `Apple/Reference/` holds the IAB VAST XSD schemas.
