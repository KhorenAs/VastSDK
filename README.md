# VASTSDK

A native VAST 4.3 linear-video ad SDK for iOS, tvOS and macOS. No Google IMA, no
VPAID, no WebView.

```swift
.package(url: "https://github.com/KhorenAs/VastSDK.git", from: "1.0.0")
```

Then depend on `VASTKit` (player and ad UI) or on `VASTCore` alone — parsing,
wrapper chains, pod scheduling and tracking, with no player at all.

```
Sources/
  VASTCore/   pure logic — does not import AVFoundation or SwiftUI
  VASTKit/    player + UI binding
  Harness/    runnable logic harness: `swift run Harness`
Examples/     VASTDemo.xcodeproj — SwiftUIDemo · UIKitDemo · AppKitDemo
Tests/        229 tests
```

Android and Web get their own repositories rather than empty folders here. The
three share the specification, the test fixtures and the behavioural decisions —
not code, and not a checkout: an Apple host has no use for Kotlin, and cloning a
dependency brings the whole repository with it.

[GO-LIVE.md](GO-LIVE.md) lists what this SDK still needs before it serves real
ads, ordered by what blocks the road rather than by effort.

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
| Pause and resume, reported as player operation metrics | ✅ |
| §6 macros — everything the session knows, plus `VASTMacroValues` for what only you do | ✅ |
| `<Extensions>` handed to the host raw | ✅ |
| `<AdVerifications>` parsed and handed over — VAST 3 and 4 shapes | ✅ |
| `<UniversalAdId>` · `<AdServingId>` · `<Advertiser>` · `<Pricing>` · `<Category>` · `<Expires>` | ✅ |
| `<CustomClick>`, kept apart from `<ClickTracking>` | ✅ |
| `<ViewableImpression>` | ✅ parsed — and `<ViewUndetermined>` is what this player can honestly send |
| `<Icon>` (AdChoices) | ✅ parsed into `ad.icons` — ❌ not drawn; see below |
| Undelivered beacons kept and retried, across launches | ✅ |
| Skip control and countdown localised (`en`, `hy`) | ✅ |
| Executing verification code (OM SDK) | ❌ by decision — `iVASTAdMeasurement` is the seam |
| NonLinear · Companion · VPAID · SIMID | ❌ by decision |
| VMAP (ad-break scheduling) | ❌ out of scope |

Ignored elements are skipped, not rejected — an unknown element never fails a
response. A response whose *only* creative is one of these is a different case:
the slot was filled, so the server hears VAST error 201 ("expecting different
linearity") on its own `<Error>` URI rather than being told it returned nothing.

VMAP is out of scope rather than pending. It answers "when do breaks happen",
which is a question about the content timeline — the host's, or its ad server's.
This SDK answers "what plays in one break, and what is reported while it does".
A host with a VMAP document reads the break times from it and calls `load` and
`play` at each one; a host whose server already schedules breaks, as most
app-side ad servers do, never needs it at all.

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

`<ViewableImpression>` follows from the same rule. §3.6 offers three outcomes —
viewable, not viewable, undetermined — and a player with no viewability
measurement can honestly claim exactly one of them, so with nothing set the SDK
sends `<ViewUndetermined>`. Saying nothing at all is the tempting option and the
wrong one: an unmeasured impression left silent is counted as measured by whoever
asked. Note the other edge of that: **setting `measurement` makes the SDK go
quiet about viewability too**, on the assumption that your adapter is measuring
it. An adapter that does not leaves the vendor hearing nothing — neither a
measurement nor an admission that there was none.

What this costs in practice is narrow and worth stating plainly. Serving your own
inventory is unaffected. What you cannot do is satisfy a buyer whose contract
requires third-party accredited measurement, because the independence is the
product, not the number. That needs the OM SDK licence, and nothing in this
package substitutes for it.

`<Icon>` is the same shape of decision, one step further along: it is parsed into
`ad.icons` — program, position, offset, resource, click-through — and not drawn.
A host that draws its own ad UI already has everything it needs to render an
AdChoices mark from that. What the SDK will not do is fetch and place an image on
your behalf and leave you unable to tell whether it appeared.

Worth being exact about the obligation, because it is easy to overstate: §3.15
expects a player to display an icon, and an `<Icon program="AdChoices">` in a
response means somebody upstream undertook to show it — under the EDAA
self-regulatory programme, or under a demand partner's own policy. That is a
contract rather than a statute, and whose contract depends on who sent the icon.

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
- **Recovering from that made pausing impossible.** Re-issuing playback every tick
  is indistinguishable, from the player alone, from a host deliberately pausing —
  so a pause was undone within one tick and reported to nobody. It has to be
  stated, which is why `pause()` exists rather than watching `rate`.
- **A host-supplied control cannot be handed back as-is.** `makeUIView` runs once
  per view identity, so returning the builder's view froze whatever the first call
  produced: a countdown that never counted, a skip control stuck on the hourglass
  it was born with. The container needs an intrinsic size too, or the control
  collapses to its minimum and its label is clipped away.
- **`UIControl` does not send `.primaryActionTriggered` from a tap.** Only
  `UIButton` does. A custom control registered for it works on tvOS, where the
  remote's select is raised by hand, and silently does nothing on iOS.
- **A fraction of the running time is the wrong thing to cut.** Ending the ad at
  97% of its duration lost nearly a second of a thirty-second creative and a third
  of that from a ten-second one. The gap that matters is one tick, so the margin is
  in seconds.
- **Rebuilding a value type drops what you forget to copy.** The Wrapper chain
  reconstructs the ad on its way out; every field added to `VASTAd` and not added
  there disappears for any response that came through a Wrapper — which is most of
  them, and invisible until a report comes back empty.

## Running things

```bash
swift build                 # VASTCore + VASTKit
swift test                  # 229 tests
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

Test fixtures under `Tests/VASTCoreTests/Fixtures/` come from the IAB sample tags
shipped with [dailymotion/vast-client-js](https://github.com/dailymotion/vast-client-js)
(MIT), used because they carry the inconsistencies real ad servers produce. One is
a live AdFox response, kept because a real server's inconsistencies are not the
ones a spec-shaped fixture has.

The parser was written against the IAB VAST 4.0, 4.1 and 4.2 XSD schemas, which
are published by the IAB Tech Lab rather than vendored here. They used to be — and
`vast_4.3.xsd` turned out to contain the fourteen bytes `404: Not Found`, which is
what happens to a file no build ever reads.

## License

MIT — see [LICENSE](LICENSE).
