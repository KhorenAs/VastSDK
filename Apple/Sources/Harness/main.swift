//
//  main.swift
//  VASTSDK Example
//
//  Command-line harness that exercises VASTCore without a player, a network or
//  a real clock. Run with `swift run Example`.
//

import Foundation
import VASTCore

// A 30s skippable ad with a full quartile set.
func makeAd() -> VASTAd {
    func url(_ s: String) -> URL { URL(string: "https://ads.example.com/\(s)")! }

    let linear = VASTAd.Linear(
        duration: 30,
        skipOffset: .time(5),
        mediaFiles: [],
        clickThrough: url("click"),
        clickTracking: [url("clicktrack")],
        trackingEvents: [
            .start: [url("start")],
            .firstQuartile: [url("q1")],
            .midpoint: [url("q2")],
            .thirdQuartile: [url("q3")],
            .complete: [url("complete")],
            .skip: [url("skip")],
        ],
        progressEvents: [.init(offset: .time(15), url: url("progress15"))]
    )
    return VASTAd(
        id: "ad-1",
        sequence: 1,
        adSystem: "Example",
        title: "Demo",
        linear: linear,
        impressions: [url("impression")],
        errors: [url("error")],
        extensions: []
    )
}

func label(_ beacon: VASTBeacon) -> String {
    switch beacon.kind {
    case .impression: "impression"
    case .tracking(let event): event.rawValue
    case .progress(let offset): "progress@\(Int(offset))s"
    case .clickTracking: "clickTracking"
    case .error(let error): "error \(error.rawValue)"
    }
}

/// Feeds a tick sequence and prints which beacons the engine emitted.
@discardableResult
func run(_ name: String, ticks: [(time: TimeInterval, wall: TimeInterval)]) -> [String] {
    var engine = VASTTrackingEngine(ad: makeAd())
    var fired: [String] = []
    for tick in ticks {
        let beacons = engine.advance(to: VASTTick(
            adTime: tick.time, duration: 30, rate: 1, wallClock: tick.wall
        ))
        fired += beacons.map(label)
    }
    print("── \(name)")
    print("   watched: \(String(format: "%.1f", engine.watched))s")
    print("   fired:   \(fired.isEmpty ? "—" : fired.joined(separator: ", "))")
    print("")
    return fired
}

// 1. Normal playback, 0 → 30s in 1s steps.
let normal = stride(from: 0.0, through: 30.0, by: 1.0).map { (time: $0, wall: $0) }
run("normal playback", ticks: normal)

// 2. Forward seek: 2s of playback, then a jump to 28s.
//    Quartiles must NOT fire — the creative was not "played continuously".
run("forward seek 2s → 28s", ticks: [
    (0, 0), (1, 1), (2, 2), (28, 3), (29, 4),
])

// 3. Rewind: play to 16s, jump back to 2s, play on.
//    Quartiles already earned must not fire a second time.
run("rewind 16s → 2s", ticks: [
    (0, 0), (8, 8), (16, 16), (2, 17), (3, 18), (4, 19),
])

// MARK: - Parser, against real IAB / vast-client-js fixtures

let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // Harness
    .deletingLastPathComponent()      // Sources
    .deletingLastPathComponent()      // Apple
    .appendingPathComponent("Tests/VASTCoreTests/Fixtures")

print("══ parser ══\n")
let parser = VASTParser()
for name in ["inline-linear", "wrapper-a", "wrapper-multiple-ads", "empty-no-ad", "outdated-vast", "invalid-xmlfile", "sample"] {
    let file = fixtures.appendingPathComponent("\(name).xml")
    guard let xml = try? String(contentsOf: file, encoding: .utf8) else {
        print("── \(name): (fixture missing)\n"); continue
    }
    do {
        let document = try parser.parse(xml)
        print("── \(name)  v\(document.version.isEmpty ? "?" : document.version)")
        if document.isNoAd {
            print("   no ad · error=\(document.noAdError?.absoluteString ?? "—")")
        }
        for entry in document.entries {
            switch entry.body {
            case .inLine(let ad):
                let events = ad.linear.trackingEvents.keys.map(\.rawValue).sorted().joined(separator: ",")
                print("   InLine \(ad.id) seq=\(entry.sequence.map(String.init) ?? "—") "
                    + "dur=\(Int(ad.linear.duration))s skip=\(ad.linear.skipOffset.map { "\($0)" } ?? "—")")
                print("     media=\(ad.linear.mediaFiles.count) imp=\(ad.impressions.count) err=\(ad.errors.count) ext=\(ad.extensions.count)")
                print("     events=[\(events)] progress=\(ad.linear.progressEvents.count)")
            case .wrapper(let wrapper):
                print("   Wrapper \(entry.id) seq=\(entry.sequence.map(String.init) ?? "—") → \(wrapper.tagURI.absoluteString)")
                print("     follow=\(wrapper.followAdditionalWrappers) multi=\(wrapper.allowMultipleAds) "
                    + "imp=\(wrapper.impressions.count) err=\(wrapper.errors.count)")
            }
        }
        print("")
    } catch {
        print("── \(name): ✋ \(error)\n")
    }
}

// MARK: - Ad-hoc: parse any file passed on the command line

for argument in CommandLine.arguments.dropFirst() {
    guard let xml = try? String(contentsOfFile: argument, encoding: .utf8) else {
        print("── \(argument): unreadable\n"); continue
    }
    print("══ \(URL(fileURLWithPath: argument).lastPathComponent) ══")
    do {
        let document = try VASTParser().parse(xml)
        print("   version \(document.version) · \(document.entries.count) entry")
        for entry in document.entries {
            guard case .inLine(let ad) = entry.body else {
                print("   Wrapper \(entry.id)"); continue
            }
            print("   InLine \(ad.id) “\(ad.title ?? "-")” system=\(ad.adSystem ?? "-")")
            print("     duration=\(Int(ad.linear.duration))s  skip=\(ad.linear.skipOffset.map { "\($0)" } ?? "—")")
            print("     media:")
            for media in ad.linear.mediaFiles {
                print("       \(media.mimeType) \(media.width ?? 0)x\(media.height ?? 0) @\(media.bitrate ?? 0)kbps \(media.delivery.rawValue)")
            }
            print("     impressions=\(ad.impressions.count) errors=\(ad.errors.count) extensions=\(ad.extensions.count)")
            print("     clickThrough=\(ad.linear.clickThrough != nil) clickTracking=\(ad.linear.clickTracking.count)")
            let parsed = ad.linear.trackingEvents.keys.map(\.rawValue).sorted()
            print("     parsed events (\(parsed.count)): \(parsed.joined(separator: ", "))")
            print("     progress events: \(ad.linear.progressEvents.count)")
        }
    } catch {
        print("   ✋ \(error)")
    }
    print("")
}

// MARK: - Live: resolve a real tag URL end to end

import VASTKit

// Unbuffered, so a killed run still shows how far it got.
setvbuf(stdout, nil, _IONBF, 0)

if let tag = ProcessInfo.processInfo.environment["VAST_TAG"].flatMap(URL.init(string:)) {
    print("══ live resolve ══")
    print("   \(tag.absoluteString)\n")
    let resolver = VASTTagResolver(loader: VASTURLSessionLoader())
    do {
        let resolution = try await resolver.resolve(tag: tag)
        print("   wrapper depth: \(resolution.chain.depth)")
        print("   ads: \(resolution.ads.count)\n")
        for ad in resolution.ads {
            print("   • \(ad.id) “\(ad.title ?? "-")” via \(ad.adSystem ?? "-")")
            print("     duration=\(Int(ad.linear.duration))s skip=\(ad.linear.skipOffset.map { "\($0)" } ?? "—")")
            for media in ad.linear.mediaFiles {
                print("     media \(media.mimeType) \(media.width ?? 0)x\(media.height ?? 0) @\(media.bitrate ?? 0)k")
            }
            print("     impressions=\(ad.impressions.count) errors=\(ad.errors.count) events=\(ad.linear.trackingEvents.count)")

            // Dry-run the tracking engine over a full 1x playback.
            var engine = VASTTrackingEngine(ad: ad)
            var fired: [String] = []
            let total = max(ad.linear.duration, 1)
            for step in stride(from: 0.0, through: total, by: 1.0) {
                fired += engine.advance(to: VASTTick(
                    adTime: step, duration: total, rate: 1, wallClock: step
                )).map(label)
            }
            print("     would fire: \(fired.joined(separator: ", "))")
        }
    } catch let failure as VASTTagResolver.Failure {
        print("   ✋ VAST \(failure.error.rawValue) \(failure.error)")
        print("   error beacons owed: \(failure.beacons.count)")
    } catch {
        print("   ✋ \(error)")
    }
    print("")
}


// MARK: - Live session (VAST_LIVE=1)

if ProcessInfo.processInfo.environment["VAST_LIVE"] == "1" {
    print("══ live session ══")
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.3"><Ad id="live"><InLine>
      <AdSystem>harness</AdSystem>
      <Impression><![CDATA[https://example.com/impression]]></Impression>
      <Creatives><Creative><Linear skipoffset="00:00:05">
        <Duration>00:00:30</Duration>
        <TrackingEvents>
          <Tracking event="start"><![CDATA[https://example.com/start]]></Tracking>
          <Tracking event="firstQuartile"><![CDATA[https://example.com/q1]]></Tracking>
          <Tracking event="complete"><![CDATA[https://example.com/complete]]></Tracking>
        </TrackingEvents>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="854" height="480">
          <![CDATA[https://media.w3.org/2010/05/sintel/trailer.mp4]]>
        </MediaFile></MediaFiles>
      </Linear></Creative></Creatives>
    </InLine></Ad></VAST>
    """
    await runLiveSession(xml: xml)
}
