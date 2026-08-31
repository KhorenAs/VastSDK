# Going live

What this SDK still needs before it serves real ads, ordered by what actually
blocks the road rather than by how hard it is. Every item names where it lives.
The two marked **verified** were reproduced with a standalone probe against the
package, and the reproduction is quoted underneath.

State at `v1.1.0`: `swift test` passes 148/148 with no warnings, `xcodebuild`
succeeds for both iOS and tvOS, and a live Google IMA sample tag resolves to six
media files and fires the expected beacon sequence.

One environment note: `swift test` fails with `no such module 'XCTest'` on any
machine whose `xcode-select` points at CommandLineTools. Export
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` until item 15 lands.

## Blockers

**1. An ad cannot be paused — verified.** `resumeIfNeeded()` is called on every
tick, so a host's pause is undone before the next frame. `state = .paused` is
never assigned either — a dead state the surface nonetheless checks — and no
`pause`/`resume` beacon is sent.

```
--- host calls player.pause() now
    immediately after pause: rate=0.0
    +0.4s after pause: rate=1.0 state=playing
    +2.0s after pause: rate=1.0 state=playing
    (no pause beacon)
```

`Apple/Sources/VASTKit/Session/VASTAdSession+Play.swift:196`

*Fix:* a `userPaused` flag that `resumeIfNeeded()` honours, plus public
`pause()`/`resume()` that report through `engine.report(.pause/.resume)` and set
the state.

**2. Host-reportable tracking is unreachable from outside.** The engine's
`report(_:)` is correct but the session never exposes it, so `mute`, `unmute`,
`pause`, `resume`, `fullscreen`, `playerExpand`, `close` and `rewind` never fire.
Separately, `loaded` is not host-reportable *and* the engine never fires it, so
that event cannot be sent at all.

*Fix:* a public `report(_ event:)` on the session, and fire `loaded` as soon as
`begin()` succeeds — before the impression.

**3. Beacon delivery is unreliable, and beacons are revenue.** `send()` hands the
batch to `Task.detached` on an ephemeral `URLSession` with no persistence and no
background task, so anything in flight when the app leaves the foreground is
lost. The transport also swallows every error, leaving the host no way to know
how many beacons never landed.

`Apple/Sources/VASTKit/Session/VASTAdSession+Play.swift:257`,
`Apple/Sources/VASTKit/Network/VASTURLSessionTransport.swift:45`

*Fix:* a queue that persists across launches and drains on start, a background
task around each flush, and a delegate hook for failures.

**4. No privacy manifest.** There is no `PrivacyInfo.xcprivacy` anywhere in the
repository. For an ad SDK — especially once `IFA` arrives with item 5 —
`NSPrivacyTracking`, the tracking domains and the required-reason API
declarations are what stand between every *host* app and an App Store rejection.

*Fix:* add the manifest as a target resource; sign the XCFramework if the SDK is
ever distributed as a binary.

## Blockers only for programmatic demand

Skip this section while the inventory is direct-sold.

**5. Macros go out almost empty.** `expandMacros` never populates `appBundle`,
`playerSize`, `isFullscreen`, `contentPlayhead` or `custom`, though the `Context`
fields are already there waiting. `IFA`, `IFATYPE`, `LIMITADTRACKING`,
`GDPRCONSENT`, `REGULATIONS`, `DEVICEUA`, `CLIENTUA`, `SERVERSIDE`,
`VASTVERSIONS`, `PLACEMENTTYPE`, `BREAKPOSITION`, `TRANSACTIONID` and
`CONTENTID` are not implemented at all, so each reports `-1`. Without `IFA` and
`APPBUNDLE` many buyers will not bid, or will treat the traffic as invalid.

`Apple/Sources/VASTKit/Session/VASTAdSession+Play.swift:311`,
`Apple/Sources/VASTCore/Track/VASTMacroExpander.swift:176`

*Fix:* fill everything the SDK already knows from the session; take the identifier
and the consent string from configuration, because only the host may ask for them.

**6. VAST 4 required and monetisation elements are not parsed.** The parser has no
mention of `UniversalAdId` (required in 4.x), `AdServingId` (required in 4.1+, and
what an ad server needs to resolve a discrepancy), `ViewableImpression` — the
basis of viewability-priced buying — `CustomClick`, `Icons` (AdChoices, required
in the EU and by Google's policy), `Expires`, `Pricing`, `Advertiser`, `Category`
or `ClosedCaptionFiles`.

`Apple/Sources/VASTCore/Parse/VASTParser.swift`

*Fix:* in order — `ViewableImpression`, then `UniversalAdId` and `AdServingId`,
then `Icons`, then the reporting fields.

**7. No Open Measurement adapter.** `iVASTAdMeasurement` is the right seam and it
is deliberately empty, so every vendor currently hears `verificationNotExecuted`.
That is the honest answer, and it is also incompatible with selling against a
viewability contract.

*Fix:* license the IAB OM SDK, then drive an adapter from the same beacons. The
longest lead time on this list — start the licensing while the blockers above are
being written.

## Important, not blocking

**8. `load(xml:)` drops a Wrapper's trackers — verified.** On `.follow`,
`resolve(xml:)` calls `resolve(tag:)`, which builds a *fresh* chain and discards
everything the outer Wrapper accumulated. The same wrapper down each path:

```
load(tag:)   impressions: [inner, outer]  errors: [outer]  depth: 1
load(xml:)   impressions: [inner]         errors: []       depth: 0
```

The depth counter restarts too, making the effective limit 2×5, and the outer
`allowMultipleAds` is never applied.

`Apple/Sources/VASTCore/Wrapper/VASTTagResolver.swift:67`

*Fix:* thread the chain through the recursion instead of creating a new one.

**9. `configuration.clock` is dead API, and it is the largest test gap.** It is
declared but read nowhere; `playOne` constructs `VASTPlayerClock` directly. So
there are 148 tests and none of them cover the playback loop — quartile firing,
the stall watchdog, skip unlocking, beacon ordering — which is the layer that
decides impressions at runtime.

`Apple/Sources/VASTKit/Session/VASTAdSession.Configuration.swift:22`,
`Apple/Sources/VASTKit/Session/VASTAdSession+Play.swift:151`

*Fix:* honour the injected clock, then add session-level tests over whole breaks.
Worth doing before item 1, so that fix arrives with a regression test.

**10. Media selection ignores the scheme.** A response offering both an `http` and
an `https` rendition may have the `http` one chosen and then fail under App
Transport Security, reported as a media error.

`Apple/Sources/VASTCore/Select/VASTMediaFileSelector.swift:72`

*Fix:* give `https` a small advantage in `cost()`.

**11. Nothing is localised.** `"Ad"`, `"Skip Ad ›"` and `"Skip in 5"` are hardcoded
English and the package ships no `.strings`. Every non-English host has to replace
all three controls to get its own language.

`Apple/Sources/VASTKit/UI/VASTAdSurface.swift:182`

*Fix:* a localised resource in the package, resolved against `Bundle.module`.

**12. Creatives are not preloaded.** Pod members load one at a time and each
`begin()` waits up to eight seconds for readiness, so a three-ad pod shows three
visible gaps.

*Fix:* prepare the next `AVPlayerItem` once the current creative passes its
midpoint.

**13. The completion threshold truncates every creative.** At `0.97`, `finish()`
sets `isFinished`, the loop breaks, and the last ~3% never plays — for a 30s ad
close to a second, which is usually where the logo is.

`Apple/Sources/VASTCore/Track/VASTTrackingEngine.swift:94`,
`Apple/Sources/VASTKit/Session/VASTAdSession+Play.swift:214`

*Fix:* fire `complete` at the threshold but let playback run to
`didPlayToEndTime`; the observer already exists.

**14. There is no CI.** No workflow exists, and
`swift test` breaks on any machine pointed at CommandLineTools. Item 9's gap will
widen quietly without one.

*Fix:* GitHub Actions across macOS, iOS and tvOS destinations, with
`DEVELOPER_DIR` set explicitly.

**15. Three small things worth one commit.** `UIScreen.main` is deprecated and
wrong under iPad multi-window or an external display, and selection uses the
screen rather than the player view. Three `print()` calls sit in shipping code
where a host cannot silence them. And there is no session-level budget: five
wrappers at five seconds plus eight seconds of readiness is thirty-three seconds
before a first frame.

`Apple/Sources/VASTKit/Session/VASTAdSession+Play.swift:360`,
`Apple/Sources/VASTKit/Session/VASTAdSession.swift:145,164,181`

## Order

| Phase | Items | Why this grouping |
|---|---|---|
| 1 — first real break on own inventory | 1, 2, 3, 4, 8, 9, 10, 11 | Mostly small and local. Do 9 first: the clock makes 1 testable rather than eyeballed. A minimal 3 (queue plus background task) is enough here. |
| 2 — programmatic demand | 5, 6, 7, 12 | 5 returns the most for the least, since half its fields are already modelled. 7 needs a licence, so begin that during phase 1. |
| 3 — polish and reach | 13, 14, 15, Android, Web | Android and Web are still *Not started*. The split that keeps `VASTCore` free of AVFoundation exists for exactly this moment: the rules and the fixtures are already written down. |

Scope note: this list assumes "live" means serving real ads in a host app. While
the inventory stays direct-sold, phase 2 defers entirely and the real blockers are
items 1 through 4.
