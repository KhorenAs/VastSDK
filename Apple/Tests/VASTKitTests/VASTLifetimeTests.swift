//
//  VASTLifetimeTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// A player and a session that outlive the screen that made them keep decoding,
/// keep observers registered, and keep the creative in memory. These check that
/// leaving the screen actually lets go.
@MainActor
final class VASTLifetimeTests: XCTestCase {

    func testSessionDeallocatesWhenTheHostReleasesIt() {
        weak var weakSession: VASTAdSession?
        weak var weakPlayer: AVPlayer?

        autoreleasepool {
            let player = AVPlayer()
            let session = VASTAdSession(player: player)
            weakSession = session
            weakPlayer = player
            XCTAssertNotNil(weakSession)
        }

        XCTAssertNil(weakSession, "the session outlived its owner")
        XCTAssertNil(weakPlayer, "the session is keeping the player alive")
    }

    /// `attach(to:)` puts a view holding the session into a container. If the
    /// session also holds that view, neither can ever be released.
    func testSessionDeallocatesAfterAttachAndDetach() {
        weak var weakSession: VASTAdSession?

        autoreleasepool {
            let session = VASTAdSession(player: AVPlayer())
            weakSession = session
            let container = PlatformView()
            session.attach(to: container)
            session.detach()
        }

        XCTAssertNil(weakSession)
    }

    /// The same, without the host remembering to detach. A container that is
    /// itself released should be enough — forgetting one call must not pin the
    /// whole session, its player and the creative in memory.
    func testSessionDeallocatesWhenHostForgetsToDetach() {
        weak var weakSession: VASTAdSession?
        weak var weakSurface: VASTAdSurfaceView?

        autoreleasepool {
            let session = VASTAdSession(player: AVPlayer())
            weakSession = session
            let container = PlatformView()
            session.attach(to: container)
            weakSurface = container.subviews.first as? VASTAdSurfaceView
            XCTAssertNotNil(weakSurface, "attach should have added the surface")
        }

        XCTAssertNil(weakSurface, "the surface outlived its container")
        XCTAssertNil(weakSession, "session ⇄ surface reference cycle")
    }

    /// `stop()` is what a screen calls on the way out, so it has to leave nothing
    /// registered behind.
    func testStopReleasesEverything() {
        weak var weakSession: VASTAdSession?

        autoreleasepool {
            let session = VASTAdSession(player: AVPlayer())
            weakSession = session
            let container = PlatformView()
            session.attach(to: container)
            session.stop()
        }

        XCTAssertNil(weakSession)
    }
}

// MARK: - After a break has actually run

extension VASTLifetimeTests {

    private static let response = """
    <VAST version="4.3"><Ad id="a"><InLine>
      <AdSystem>test</AdSystem>
      <Impression><![CDATA[https://ads.test/impression]]></Impression>
      <Creatives><Creative><Linear>
        <Duration>00:00:05</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile></MediaFiles>
      </Linear></Creative></Creatives>
    </InLine></Ad></VAST>
    """

    /// A break installs a periodic time observer on the player and application
    /// notification observers. Any of those left registered outlives the screen
    /// and keeps the session — and the player still decoding — alive.
    func testSessionDeallocatesAfterAFullBreak() async {
        weak var weakSession: VASTAdSession?
        weak var weakPlayer: AVPlayer?

        await withCheckedContinuation { continuation in
            Task { @MainActor in
                autoreleasepool {
                    let player = AVPlayer()
                    let session = VASTAdSession(
                        player: player,
                        configuration: VASTAdSession.Configuration(
                            restoresPlayerItem: false,
                            loader: StubResponseLoader(xml: Self.response)
                        )
                    )
                    weakSession = session
                    weakPlayer = player

                    Task { @MainActor in
                        try? await session.load(tag: URL(string: "https://ads.test/tag")!)
                        // The creative URL is unreachable, so the break fails on
                        // media rather than playing — which is the teardown path
                        // most likely to leave something registered.
                        _ = await session.play()
                        continuation.resume()
                    }
                }
            }
        }

        // Let the break's own task finish releasing its captures.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(weakSession, "something registered during the break still holds the session")
        XCTAssertNil(weakPlayer, "the player is still retained after the break")
    }

    /// The clock installs the observer that drives everything; if it survives, so
    /// does the block it handed to `AVPlayer`.
    func testClockDeallocatesAfterStop() {
        weak var weakClock: VASTPlayerClock?

        autoreleasepool {
            let player = AVPlayer()
            let item = AVPlayerItem(url: URL(string: "https://ads.test/v.mp4")!)
            let clock = VASTPlayerClock(player: player, adItem: item)
            weakClock = clock
            _ = clock.ticks()
            clock.stop()
        }

        XCTAssertNil(weakClock)
    }
}

private struct StubResponseLoader: iVASTResourceLoader {
    let xml: String
    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String { xml }
}

// MARK: - Abandoned mid-break

extension VASTLifetimeTests {

    /// The reported symptom, reduced: enter the screen, start a break, leave
    /// before it finishes. An `AVPlayer` subclass with a `deinit` print never
    /// printed, which is what proved the player was being kept alive.
    ///
    /// The cause was a cycle. `play()` stored its task in `activeBreak` — a
    /// property of the session — while the task captured the session strongly.
    /// It only came apart if `play()` ran to completion, so abandoning it left the
    /// session, its player and the creative alive for good.
    func testSessionDeallocatesWhenTheBreakIsAbandonedMidFlight() async {
        weak var weakSession: VASTAdSession?
        weak var weakPlayer: AVPlayer?

        await withCheckedContinuation { continuation in
            Task { @MainActor in
                autoreleasepool {
                    let player = AVPlayer()
                    let session = VASTAdSession(
                        player: player,
                        configuration: VASTAdSession.Configuration(
                            restoresPlayerItem: false,
                            loader: StubResponseLoader(xml: Self.response)
                        )
                    )
                    weakSession = session
                    weakPlayer = player

                    Task { @MainActor in
                        try? await session.load(tag: URL(string: "https://ads.test/tag")!)
                        // Deliberately not awaited: this is a host that walks away
                        // while the break is running.
                        Task { @MainActor in _ = await session.play() }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        session.stop()
                        continuation.resume()
                    }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(weakSession, "session ⇄ activeBreak reference cycle")
        XCTAssertNil(weakPlayer, "the player outlived the session that owned it")
    }

    /// Repeated enter/leave, each time abandoning the break. Every player has to
    /// go — one surviving instance is a sound with no screen.
    func testRepeatedAbandonedBreaksLeaveNothingAlive() async {
        var players: [() -> AVPlayer?] = []

        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    weak var weakPlayer: AVPlayer?
                    autoreleasepool {
                        let player = AVPlayer()
                        weakPlayer = player
                        let session = VASTAdSession(
                            player: player,
                            configuration: VASTAdSession.Configuration(
                                restoresPlayerItem: false,
                                loader: StubResponseLoader(xml: Self.response)
                            )
                        )
                        Task { @MainActor in
                            try? await session.load(tag: URL(string: "https://ads.test/tag")!)
                            Task { @MainActor in _ = await session.play() }
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            session.stop()
                            continuation.resume()
                        }
                    }
                    players.append { weakPlayer }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 600_000_000)
        for (index, player) in players.enumerated() {
            XCTAssertNil(player(), "player \(index) is still alive")
        }
    }
}

// MARK: - The cycle in isolation

extension VASTLifetimeTests {

    /// Isolates the `session ⇄ activeBreak` cycle by never calling `stop()`.
    ///
    /// `stop()` clears `activeBreak`, which hides the cycle. A host that simply
    /// walks away — the view is gone, nobody calls anything — is the case that
    /// exposes it: `play()`'s caller is abandoned, so nothing ever clears the
    /// task, and a task that captured the session strongly keeps it forever.
    func testSessionDeallocatesWhenAbandonedWithoutStop() async {
        weak var weakSession: VASTAdSession?
        weak var weakPlayer: AVPlayer?

        await withCheckedContinuation { continuation in
            Task { @MainActor in
                autoreleasepool {
                    let player = AVPlayer()
                    let session = VASTAdSession(
                        player: player,
                        configuration: VASTAdSession.Configuration(
                            restoresPlayerItem: false,
                            loader: StubResponseLoader(xml: Self.response)
                        )
                    )
                    weakSession = session
                    weakPlayer = player

                    Task { @MainActor in
                        try? await session.load(tag: URL(string: "https://ads.test/tag")!)
                        // Abandoned: the result is never awaited and `stop()` is
                        // never called, exactly as when a screen disappears.
                        Task { @MainActor in _ = await session.play() }
                        continuation.resume()
                    }
                }
            }
        }

        // Long enough for the break to fail on its unreachable creative and for
        // its task to finish. If the cycle is present, finishing changes nothing.
        try? await Task.sleep(nanoseconds: 10_000_000_000)

        XCTAssertNil(weakSession, "session ⇄ activeBreak cycle survives an abandoned break")
        XCTAssertNil(weakPlayer)
    }
}
