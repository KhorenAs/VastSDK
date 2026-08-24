# VASTSDK — Apple

A native VAST 4.3 linear-video ad SDK for iOS, tvOS and macOS. No Google IMA, no
VPAID, no WebView.

```
Sources/
  VASTCore/   pure logic — does not import AVFoundation or SwiftUI
  VASTKit/    player + UI binding
  Harness/    runnable logic harness: `swift run Harness`
Examples/
  VASTDemo.xcodeproj    SwiftUIDemo · UIKitDemo · AppKitDemo
Tests/        148 tests
Reference/    IAB VAST 4.0/4.1/4.2 XSD schemas
```

## Using it

```swift
let session = VASTAdSession(player: myPlayer)

try await session.load(tag: adTagURL)   // follows Wrapper chains
await session.play()                    // plays the pod, reports tracking
```

SwiftUI hosts compose the ad UI over their player:

```swift
ZStack {
    MyPlayerView(player: player)
    VASTAdSurface(session: session)
}
```

UIKit and AppKit hosts hand the SDK a container instead:

```swift
session.attach(to: playerOverlayView)
```

Every element of the surface is replaceable — `vastSkipButton`, `vastAdBadge`,
`vastCountdown`, `vastClickThrough` — so the SDK owns the *behaviour* the spec
requires while the host owns the look. A replaced skip control is still wrapped
in a `Button`, so it stays focusable and hittable on every platform, and its
drawn size is checked: a builder that returns nothing is reported rather than
silently leaving a skippable ad unskippable.

On tvOS there is no pointer, so `clickPresentation = .surface` cannot work — a
transparent layer takes no focus. The session says so through the delegate
instead of drawing something inert; a tvOS host uses `.host` with a focusable
control of its own, or `.disabled`.

## What it covers

| | |
|---|---|
| Linear ads | ✅ |
| Skippable Linear (`skipoffset`) | ✅ |
| Ad Pods (`sequence`) + stand-alone substitution | ✅ |
| Wrapper chains (depth ≤ 5, tracker accumulation, error fan-out) | ✅ |
| Tracking: impression, quartiles, progress offsets, skip, click, error | ✅ |
| VAST 2.0/3.0 legacy event names | ✅ |
| §6 macros (`[ERRORCODE]`, `[ADPLAYHEAD]`, `[CACHEBUSTING]`, …) | ✅ |
| `<Extensions>` handed to the host raw | ✅ |
| `<AdVerifications>` parsed and handed over — VAST 3 and 4 shapes | ✅ |
| Executing verification code (OM SDK) | ❌ by decision — `iVASTAdMeasurement` is the seam |
| NonLinear · Companion · VPAID · SIMID · Icons | ❌ by decision |
| VMAP (ad-break scheduling) | ❌ not yet |

Ignored elements are skipped, not rejected — an unknown element never fails a
response. A response whose *only* creative is one of these is a different case:
the slot was filled, so the server hears VAST error 201 ("expecting different
linearity") on its own `<Error>` URI rather than being told it returned nothing.

## Four decisions worth knowing

**Compliance is enforced, not hoped for.** `SkipPresentation` says who provides
the skip control. Under `.unsupported`, a skippable ad is refused with VAST error
200 rather than played without one, because §2.3 forbids exactly that. The
default is `.sdk`, so a host that configures nothing is compliant.

**Verification is described, not executed.** `<AdVerifications>` is parsed —
including the VAST 3 shape, where vendors shipped it inside
`<Extension type="AdVerifications">` — and normalised into `ad.adVerifications`,
so a host cannot tell which version answered. Running that code means the IAB
Open Measurement SDK, which is licensed separately and stays outside this
package. `iVASTAdMeasurement` is the seam:

```swift
session.measurement = MyOpenMeasurementAdapter()
```

With nothing set, every vendor that asked is sent `verificationNotExecuted` —
reason 1 where no OMID resource exists, reason 3 where one does and nothing ran
it. With an adapter set the SDK goes quiet, drives the adapter from the same
beacons the ad server receives, and takes `resourceLoadError` back through
`reportVerificationNotExecuted(_:reason:)`, which only the loader can know.

**`.host` transfers the obligation, and nothing checks it.** Under
`skipPresentation = .host` or `clickPresentation = .host` the SDK draws no
control and makes no claim about whether you drew one. It cannot: it does not
know your view tree. That mode is a statement that §2.3 and §3.10.1 are yours to
honour — the SDK's own promises hold only for `.sdk` and `.surface`.

**The correctness-critical logic never touches AVPlayer.** `VASTCore` cannot
import AVFoundation — the compiler enforces it. Time arrives as `VASTTick`
values, and the tracking engine returns beacons instead of sending them. That is
why quartile behaviour, seek rejection, pod substitution and wrapper limits are
all testable with no player, no network and no waiting.

## Things that are easy to get wrong

Each of these is a bug that was found and is now pinned by a test.

- **Quartiles measure covered timeline, not accumulated deltas.** A stall does not
  skip any of the creative; a seek does. Summing playback deltas discounts stalls,
  so on a stuttering connection `complete` never fires and the ad hangs.
- **Tracking is never awaited from the playback loop.** One unreachable tracking
  host froze the countdown, the skip control and the end of the ad.
- **`AVPlayerItem.status` is polled, not observed.** If the item settles before an
  async `publisher(for:).values` sequence is subscribed, the transition is never
  delivered and the break stops with the creative never appearing.
- **`try? await Task.sleep` swallows cancellation.** A dismissed screen carried on
  into the break — audible, with nothing left to stop it.
- **`URL(string:)` percent-encodes brackets**, so `[ERRORCODE]` arrives as
  `%5BERRORCODE%5D`; and a leftover vendor macro makes Foundation re-encode the
  whole string, double-encoding values that were already correct.
- **iOS never resumes playback after backgrounding.** `rate` is left at 0, and a
  stall watchdog that keys on `rate > 0` cannot tell that apart from a hang.

## Running things

```bash
swift build                 # VASTCore + VASTKit
swift test                  # 148 tests
swift run Harness           # tracking engine + parser against fixtures
```

```bash
open Examples/VASTDemo.xcodeproj
```

Then pick a scheme — SwiftUIDemo, UIKitDemo, AppKitDemo — and a destination.
The demo's scenario list covers two live tags from Google's public IMA sample
inventory, skippable and non-skippable responses, a three-ad pod, a no-fill
response and an unplayable creative. The list footer shows live player-screen
count; it must read zero once no player screen is open.

## Requirements

iOS 16 · tvOS 16 · macOS 13 · Swift 6 (strict concurrency)

`Reference/` holds the IAB XSD schemas. Test fixtures under
`Tests/VASTCoreTests/Fixtures/` come from the IAB sample tags shipped with
[dailymotion/vast-client-js](https://github.com/dailymotion/vast-client-js) (MIT),
used because they carry the inconsistencies real ad servers produce.
