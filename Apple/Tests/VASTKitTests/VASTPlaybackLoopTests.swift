//
//  VASTPlaybackLoopTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// The loop inside `playOne` — the thing that decides which beacons a real
/// session sends — had no test of its own. Every other suite either drives the
/// engine directly, with no session around it, or stops at the media stage
/// because the creative URL is unreachable.
///
/// These run the whole session: parse, select, load a creative that really
/// decodes, then drive the tick loop from a scripted clock rather than from a
/// player's timing. Nothing here waits on real time.
@MainActor
final class VASTPlaybackLoopTests: XCTestCase {

    private var creative: URL!

    override func setUp() async throws {
        try await super.setUp()
        creative = try Self.playableFile()
    }

    override func tearDown() async throws {
        if let creative { try? FileManager.default.removeItem(at: creative) }
        creative = nil
        try await super.tearDown()
    }

    // MARK: - The full sequence

    /// Impression, `creativeView`, `start`, three quartiles and `complete`, from
    /// one pass at 1×. Also the proof that `configuration.clock` is honoured at
    /// all: with the player's own clock this ad would need twenty real seconds.
    func testAScriptedBreakFiresEveryBeaconTheAdAskedForAndCompletes() async throws {
        let transport = RecordingTransport()
        let clock = ScriptedClock(script: [
            Self.tick(at: 0, wall: 0),
            Self.tick(at: 5, wall: 5),
            Self.tick(at: 10, wall: 10),
            Self.tick(at: 15, wall: 15),
            // Within one tick of the end, which is what a player reports when a
            // creative plays out.
            Self.tick(at: 19.9, wall: 19.9),
        ])
        let session = makeSession(clock: clock, transport: transport)

        try await session.load(tag: Self.tag)
        let outcome = await session.play()

        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(
            clock.didProduceTicks,
            "configuration.clock was ignored — the built-in player clock ran instead"
        )

        let fired = await recorded(from: transport, atLeast: 7).map(Self.label)
        // Membership, not order: each batch goes out on its own detached task, so
        // arrival order across ticks is deliberately not guaranteed by the SDK.
        XCTAssertEqual(Set(fired), [
            "impression", "creativeView", "start",
            "firstQuartile", "midpoint", "thirdQuartile", "complete",
        ])
        XCTAssertEqual(
            fired.filter { $0 == "impression" }.count, 1,
            "an impression is owed once per ad, whatever the tick rate"
        )
    }

    /// §3.14.1 gives the quartiles to continuous playback. A jump the elapsed
    /// wall clock cannot account for is a seek, and a seek earns nothing — which
    /// the engine enforces, and this checks still holds with a session, a real
    /// creative and the real loop around it.
    func testAForwardSeekDoesNotEarnTheQuartilesItSkipped() async throws {
        let transport = RecordingTransport()
        let clock = ScriptedClock(script: [
            Self.tick(at: 0, wall: 0),
            Self.tick(at: 1, wall: 1),
            // One second later the playhead is at 16s. Only a seek does that.
            Self.tick(at: 16, wall: 2),
            Self.tick(at: 17, wall: 3),
        ])
        let session = makeSession(clock: clock, transport: transport)

        try await session.load(tag: Self.tag)
        let outcome = await session.play()

        let fired = await recorded(from: transport, atLeast: 3).map(Self.label)
        XCTAssertTrue(fired.contains("impression"))
        XCTAssertTrue(fired.contains("start"))
        for skipped in ["firstQuartile", "midpoint", "thirdQuartile", "complete"] {
            XCTAssertFalse(fired.contains(skipped), "\(skipped) was earned by seeking")
        }
        XCTAssertEqual(outcome, .failed(.mediaFileTimeout), "an unwatched creative is not a completion")
    }

    // MARK: - Pause

    /// The regression this suite exists for.
    ///
    /// `resumeIfNeeded()` runs on every tick, so before `pause()` existed a host
    /// pause was undone inside one tick and the viewer could not pause an ad at
    /// all. The paused stretch here also spans eighteen scripted seconds — well
    /// past `stallTimeout` — because the second half of the same bug was the
    /// watchdog writing a paused ad off as unplayable.
    func testAHostPauseHoldsAndIsReported() async throws {
        let transport = RecordingTransport()
        let player = AVPlayer()

        // The clock is built before the session it drives, so the session — and
        // what the closure sees — travel through this. `beforeTick` runs on the
        // main actor after the session has finished acting on every earlier tick,
        // because the stream produces on demand; that is what makes the
        // interleaving deterministic rather than hopeful.
        let probe = PauseProbe()
        let clock = ScriptedClock(script: [
            Self.tick(at: 0, wall: 0),
            Self.tick(at: 2, wall: 2),
            // Paused: the playhead stands still while the wall clock runs on.
            Self.tick(at: 2, wall: 3, rate: 0),
            Self.tick(at: 2, wall: 12, rate: 0),
            Self.tick(at: 2, wall: 20, rate: 0),
            // Resumed, and the rest of the creative plays out.
            Self.tick(at: 3, wall: 21),
            Self.tick(at: 10, wall: 28),
            Self.tick(at: 19.9, wall: 37.9),
        ]) { index in
            guard let session = probe.session else { return }
            switch index {
            case 2:
                session.pause()
                probe.stateWhilePaused = session.state
            case 3:
                // Read one tick later, not at the moment of pausing: the watchdog
                // runs while a tick is being handled, so the resume it used to
                // issue only shows up once the session has processed tick 2.
                probe.rateWhilePaused = player.rate
            case 5:
                session.resume()
                probe.rateAfterResume = player.rate
            default:
                break
            }
        }

        let session = makeSession(player: player, clock: clock, transport: transport)
        probe.session = session

        try await session.load(tag: Self.tag)
        let outcome = await session.play()

        XCTAssertEqual(
            probe.rateWhilePaused, 0,
            "the resume watchdog handed playback back a tick after the host paused"
        )
        XCTAssertEqual(probe.stateWhilePaused, .paused)
        XCTAssertEqual(probe.rateAfterResume, 1, "resume() did not hand playback back")

        let fired = await recorded(from: transport, atLeast: 9).map(Self.label)
        XCTAssertTrue(fired.contains("pause"), "the ad server was not told about the pause")
        XCTAssertTrue(fired.contains("resume"))
        XCTAssertFalse(
            fired.contains("error402"),
            "eighteen paused seconds were mistaken for a dead stream"
        )
        XCTAssertEqual(outcome, .completed, "the break did not survive being paused")
    }

    /// Nothing is owed to anyone for a pause with no ad on screen, so it is a
    /// no-op rather than an error — unlike `skip()`, which §2.3 makes a promise
    /// about and which therefore throws.
    func testPauseAndResumeDoNothingWithNoAdOnScreen() {
        let session = VASTAdSession(player: AVPlayer())

        session.pause()
        XCTAssertEqual(session.state, .idle)

        session.resume()
        XCTAssertEqual(session.state, .idle)
    }

    /// A system pause is not the host's to lift: it clears itself when the app
    /// comes back, and `resume()` must not claim otherwise.
    func testResumeDoesNotOverrideAPauseTheSystemImposed() {
        let session = VASTAdSession(player: AVPlayer())
        session.state = .playing

        session.resume()
        XCTAssertEqual(session.state, .playing, "resume() moved a state it does not own")
    }
}

// MARK: - Session under test

private extension VASTPlaybackLoopTests {

    static let tag = URL(string: "https://ads.test/tag")!

    /// A 20s non-skippable ad with the full tracking set, pointing at a creative
    /// that really exists.
    func response() -> String {
        """
        <VAST version="4.3"><Ad id="a"><InLine>
          <AdSystem>test</AdSystem>
          <Error><![CDATA[https://ads.test/error?code=[ERRORCODE]]]></Error>
          <Impression><![CDATA[https://ads.test/impression]]></Impression>
          <Creatives><Creative><Linear>
            <Duration>00:00:20</Duration>
            <TrackingEvents>
              <Tracking event="creativeView"><![CDATA[https://ads.test/creativeView]]></Tracking>
              <Tracking event="start"><![CDATA[https://ads.test/start]]></Tracking>
              <Tracking event="firstQuartile"><![CDATA[https://ads.test/q1]]></Tracking>
              <Tracking event="midpoint"><![CDATA[https://ads.test/q2]]></Tracking>
              <Tracking event="thirdQuartile"><![CDATA[https://ads.test/q3]]></Tracking>
              <Tracking event="complete"><![CDATA[https://ads.test/complete]]></Tracking>
              <Tracking event="pause"><![CDATA[https://ads.test/pause]]></Tracking>
              <Tracking event="resume"><![CDATA[https://ads.test/resume]]></Tracking>
            </TrackingEvents>
            <MediaFiles>
              <!-- The declared type is what selection reads; AVFoundation decodes
                   whatever the URL really holds. What is under test is the loop
                   above the player, not the decoder. -->
              <MediaFile delivery="progressive" type="video/mp4"><![CDATA[\(creative.absoluteString)]]></MediaFile>
            </MediaFiles>
          </Linear></Creative></Creatives>
        </InLine></Ad></VAST>
        """
    }

    func makeSession(
        player: AVPlayer = AVPlayer(),
        clock: any iVASTClock,
        transport: RecordingTransport
    ) -> VASTAdSession {
        VASTAdSession(
            player: player,
            configuration: VASTAdSession.Configuration(
                restoresPlayerItem: false,
                clock: clock,
                transport: transport,
                loader: StubLoader(xml: response())
            )
        )
    }

    static func tick(at time: TimeInterval, wall: TimeInterval, rate: Float = 1) -> VASTTick {
        VASTTick(adTime: time, duration: 20, rate: rate, wallClock: wall)
    }

    static func label(_ beacon: VASTBeacon) -> String {
        switch beacon.kind {
        case .impression: "impression"
        case .tracking(let event): event.rawValue
        case .progress(let offset): "progress@\(Int(offset))"
        case .clickTracking: "click"
        case .error(let error): "error\(error.rawValue)"
        case .verificationNotExecuted: "notExecuted"
        }
    }

    /// Beacons leave on detached tasks, so they can still be in flight when
    /// `play()` returns. Waits for the count the test expects rather than for a
    /// fixed delay.
    func recorded(from transport: RecordingTransport, atLeast count: Int) async -> [VASTBeacon] {
        for _ in 0..<200 {
            let beacons = await transport.recorded()
            if beacons.count >= count { return beacons }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await transport.recorded()
    }

    /// A file `AVPlayerItem` will report `.readyToPlay` for.
    ///
    /// The break does not start until the creative is playable, which is why the
    /// other session suites all stop at the media stage. Ten seconds of silent
    /// PCM is the cheapest thing AVFoundation plays with no encoder involved, and
    /// it is long enough that its own end never arrives during a scripted run.
    static func playableFile(seconds: Int = 10) throws -> URL {
        let sampleRate = 8_000, channels = 1, bits = 16
        let blockAlign = channels * bits / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = byteRate * seconds

        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u16(_ value: Int) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bits)
        ascii("data"); u32(dataSize)
        data.append(Data(count: dataSize))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vast-loop-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}

// MARK: - Doubles

/// A tick source with no player and no real time.
///
/// Produces on demand rather than up front, so `beforeTick` for tick *n* runs
/// only after the session has finished acting on tick *n-1*. That is what lets a
/// test call `pause()` at an exact point in the loop instead of hoping.
private final class ScriptedClock: iVASTClock, @unchecked Sendable {

    private let script: [VASTTick]
    private let beforeTick: (@MainActor (Int) -> Void)?
    private var index = 0
    private var stopped = false

    /// Whether the session actually consumed this clock, as opposed to building
    /// its own and leaving `configuration.clock` unread.
    private(set) var didProduceTicks = false

    init(script: [VASTTick], beforeTick: (@MainActor (Int) -> Void)? = nil) {
        self.script = script
        self.beforeTick = beforeTick
    }

    func ticks() -> AsyncStream<VASTTick> {
        AsyncStream(unfolding: { [weak self] in
            await MainActor.run { self?.next() }
        })
    }

    func stop() {
        MainActor.assumeIsolated { stopped = true }
    }

    @MainActor
    private func next() -> VASTTick? {
        guard !stopped, index < script.count else { return nil }
        didProduceTicks = true
        let tick = script[index]
        beforeTick?(index)
        index += 1
        return tick
    }
}

/// What the pause test hands to its clock, and reads back afterwards.
///
/// A class rather than captured locals: the clock's hook is `@Sendable`, and a
/// local `var` assigned after being captured by one is a warning — correctly, it
/// is a mutation racing the capture. Main-actor isolation makes this safe.
@MainActor
private final class PauseProbe {
    var session: VASTAdSession?
    var rateWhilePaused: Float?
    var stateWhilePaused: VASTAdSession.State?
    var rateAfterResume: Float?
}

/// Answers from memory, so a session runs with no network.
private struct StubLoader: iVASTResourceLoader {
    let xml: String
    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String { xml }
}

/// Records what was fired instead of sending it.
private actor RecordingTransport: iVASTBeaconTransport {
    private var beacons: [VASTBeacon] = []
    func fire(_ beacons: [VASTBeacon]) async { self.beacons += beacons }
    func recorded() -> [VASTBeacon] { beacons }
}
