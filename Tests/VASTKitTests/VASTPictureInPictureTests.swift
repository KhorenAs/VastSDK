//
//  VASTPictureInPictureTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// A configuration type written before `pictureInPicture` existed. It has to go
/// on compiling, and it has to come out compliant: that is the whole point of
/// giving the requirement a default rather than adding it bare.
private struct LegacyConfiguration: VASTAdSession.iConfiguration {
    var maxWrapperDepth = 5
    var wrapperTimeout: TimeInterval = 5
    var restoresPlayerItem = false
    var skipPresentation: VASTAdSession.SkipPresentation = .sdk
    var clickPresentation: VASTAdSession.ClickPresentation = .surface
    var clock: (any iVASTClock)?
    var transport: (any iVASTBeaconTransport)?
    var loader: (any iVASTResourceLoader)?
}

private final class DelegateSpy: iVASTAdSessionDelegate {
    var changes: [Bool] = []
    var skipReasons: [String] = []
    var clickReasons: [String] = []

    func session(_ session: VASTAdSession, pictureInPictureDidChange isActive: Bool) {
        changes.append(isActive)
    }
    func session(_ session: VASTAdSession, skipControlUnavailableFor ad: VASTAd, reason: String) {
        skipReasons.append(reason)
    }
    func session(_ session: VASTAdSession, clickThroughUnavailableFor ad: VASTAd, reason: String) {
        clickReasons.append(reason)
    }
}

/// Picture in Picture follows the player *layer*, so the creative goes into the
/// window whether or not anyone decided it should — and the skip control and
/// click layer, being views in the app, do not go with it.
///
/// `AVPictureInPictureController` cannot be built in a test process, so what is
/// covered here is the half that decides: the policy, and everything the session
/// does with its answer. The coordinator is the thin part that carries it out.
@MainActor
final class VASTPictureInPictureTests: XCTestCase {

    private func makeSession(
        _ policy: VASTAdSession.PictureInPicturePolicy,
        skipPresentation: VASTAdSession.SkipPresentation = .sdk,
        clickPresentation: VASTAdSession.ClickPresentation = .surface
    ) -> VASTAdSession {
        VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(
                restoresPlayerItem: false,
                skipPresentation: skipPresentation,
                clickPresentation: clickPresentation,
                pictureInPicture: policy
            )
        )
    }

    private func skippableAd(
        clickThrough: URL? = URL(string: "https://ads.test/click")
    ) -> VASTAd {
        VASTAd(
            id: "a1",
            linear: VASTAd.Linear(
                duration: 30,
                skipOffset: .time(5),
                mediaFiles: [],
                clickThrough: clickThrough,
                clickTracking: [],
                trackingEvents: [:],
                progressEvents: []
            )
        )
    }

    /// The one state in which a policy applies: an ad on screen, a break running.
    ///
    /// `canSkip` because that is when §2.3 promises something reachable — the
    /// window costs nothing before the offset elapses, and the SDK says nothing
    /// then either.
    private func playing(_ session: VASTAdSession, ad: VASTAd? = nil, canSkip: Bool = true) {
        session.currentAd = ad ?? skippableAd()
        session.activePlayback = VASTPlaybackController(player: session.player)
        session.state = .playing
        session.canSkip = canSkip
    }

    // MARK: - The default

    /// A host that never mentions the window has the window left alone, whether
    /// it uses the shipped `Configuration` or a type of its own that predates
    /// the setting.
    func testDefaultPolicyLeavesTheWindowAlone() {
        XCTAssertEqual(VASTAdSession.Configuration().pictureInPicture, .allowed)
        XCTAssertEqual(LegacyConfiguration().pictureInPicture, .allowed)
        XCTAssertEqual(
            VASTAdSession(player: AVPlayer(), configuration: LegacyConfiguration())
                .configuration.pictureInPicture,
            .allowed
        )
    }

    // MARK: - The decision

    func testReactionsAreTheOnesEachPolicyPromises() {
        XCTAssertEqual(
            VASTAdSession.PictureInPicturePolicy.suspended.reaction(toPictureInPictureActive: true),
            .stopPictureInPicture
        )
        XCTAssertEqual(
            VASTAdSession.PictureInPicturePolicy.suspended.reaction(toPictureInPictureActive: false),
            .ignore
        )
        XCTAssertEqual(
            VASTAdSession.PictureInPicturePolicy.pausesAd.reaction(toPictureInPictureActive: true),
            .pauseAd
        )
        XCTAssertEqual(
            VASTAdSession.PictureInPicturePolicy.pausesAd.reaction(toPictureInPictureActive: false),
            .resumeAd
        )
        XCTAssertEqual(
            VASTAdSession.PictureInPicturePolicy.allowed.reaction(toPictureInPictureActive: true),
            .reportUnreachableUI
        )
        XCTAssertEqual(
            VASTAdSession.PictureInPicturePolicy.allowed.reaction(toPictureInPictureActive: false),
            .ignore
        )
    }

    // MARK: - Outside a break

    /// Between breaks the window is the host's. Closing one the SDK has no ad in
    /// would be taking a feature away from an app that is not showing an ad.
    func testWindowIsLeftAloneWhenNoAdIsPlaying() {
        let session = makeSession(.suspended)
        let spy = DelegateSpy()
        session.delegate = spy

        XCTAssertEqual(session.notePictureInPicture(isActive: true), .ignore)
        XCTAssertTrue(session.isInPictureInPicture)
        XCTAssertEqual(spy.changes, [true])
    }

    /// A repeated report is not a second trip into the window.
    func testDelegateHearsTransitionsRatherThanRepeats() {
        let session = makeSession(.suspended)
        let spy = DelegateSpy()
        session.delegate = spy

        session.notePictureInPicture(isActive: true)
        session.notePictureInPicture(isActive: true)
        session.notePictureInPicture(isActive: false)

        XCTAssertEqual(spy.changes, [true, false])
    }

    // MARK: - .suspended

    func testSuspendedAsksForTheWindowToBeClosed() {
        let session = makeSession(.suspended)
        playing(session)

        XCTAssertEqual(session.notePictureInPicture(isActive: true), .stopPictureInPicture)
        // Closing it is the answer, not pausing: the ad carries on where its
        // controls are.
        XCTAssertEqual(session.state, .playing)
    }

    // MARK: - .pausesAd

    /// Nothing should play where nobody can skip it. Pausing is reported as a
    /// §3.14.1 `pause`, which is why it goes through the session rather than the
    /// player.
    func testPausesAdHoldsTheAdForTheLengthOfTheWindow() {
        let session = makeSession(.pausesAd)
        playing(session)

        XCTAssertEqual(session.notePictureInPicture(isActive: true), .pauseAd)
        XCTAssertEqual(session.state, .paused)

        XCTAssertEqual(session.notePictureInPicture(isActive: false), .resumeAd)
        XCTAssertEqual(session.state, .playing)
    }

    // MARK: - .allowed

    /// The §2.3 promise, broken in a way `VASTSurfacePresence` cannot see: the
    /// surface is on screen and correctly sized, and the ad is somewhere else.
    func testAllowedReportsASkipControlTheViewerCannotSee() {
        let session = makeSession(.allowed)
        let spy = DelegateSpy()
        session.delegate = spy
        playing(session)

        XCTAssertEqual(session.notePictureInPicture(isActive: true), .reportUnreachableUI)
        XCTAssertEqual(spy.skipReasons.count, 1)
        XCTAssertEqual(session.state, .playing, "the ad is allowed to keep playing")
    }

    /// Tapping the window returns to the app, where the click layer is exactly
    /// where it was — a tap further away, not unreachable, and not worth a
    /// warning on every ad anyone watches in the window.
    func testAllowedDoesNotComplainAboutTheClickPath() {
        let session = makeSession(.allowed)
        let spy = DelegateSpy()
        session.delegate = spy
        playing(session)

        session.notePictureInPicture(isActive: true)

        XCTAssertTrue(spy.clickReasons.isEmpty)
    }

    /// Before `skipoffset` elapses no control is owed, so the window costs
    /// nothing and the SDK says nothing.
    func testAllowedSaysNothingBeforeTheSkipControlIsDue() {
        let session = makeSession(.allowed)
        let spy = DelegateSpy()
        session.delegate = spy
        playing(session, canSkip: false)

        session.notePictureInPicture(isActive: true)

        XCTAssertTrue(spy.skipReasons.isEmpty)

        // And said once the offset elapses with the viewer still out there. The
        // surface is reported at a usable size first, so the only thing left to
        // complain about is where the ad is — not where the surface is.
        session.noteSurface(size: CGSize(width: 640, height: 360))
        session.canSkip = true
        session.verifySkipSurface(for: session.currentAd!)
        XCTAssertEqual(spy.skipReasons.count, 1)
    }

    /// One complaint per ad. Leaving the window and coming back is the same
    /// mistake, not a new one.
    func testAllowedComplainsOncePerAd() {
        let session = makeSession(.allowed)
        let spy = DelegateSpy()
        session.delegate = spy
        playing(session)

        session.notePictureInPicture(isActive: true)
        session.notePictureInPicture(isActive: false)
        session.notePictureInPicture(isActive: true)
        XCTAssertEqual(spy.skipReasons.count, 1)

        // The next ad in the pod gets its own chance to be wrong.
        session.resetComplianceReports()
        session.notePictureInPicture(isActive: true)
        XCTAssertEqual(spy.skipReasons.count, 2)
    }

    /// A host that took both promises over is not told it broke them.
    func testAllowedSaysNothingWhenTheHostOwnsTheUI() {
        let session = makeSession(.allowed, skipPresentation: .host, clickPresentation: .host)
        let spy = DelegateSpy()
        session.delegate = spy
        playing(session)

        session.notePictureInPicture(isActive: true)

        XCTAssertTrue(spy.skipReasons.isEmpty)
        XCTAssertTrue(spy.clickReasons.isEmpty)
    }

    /// A non-skippable ad was never promised a control, so nothing is owed and
    /// nothing is said.
    func testAllowedSaysNothingForANonSkippableAd() {
        let session = makeSession(.allowed)
        let spy = DelegateSpy()
        session.delegate = spy
        playing(session, ad: VASTAd(
            id: "a2",
            linear: VASTAd.Linear(
                duration: 15,
                skipOffset: nil,
                mediaFiles: [],
                clickThrough: URL(string: "https://ads.test/click"),
                clickTracking: [],
                trackingEvents: [:],
                progressEvents: []
            )
        ))

        session.notePictureInPicture(isActive: true)

        XCTAssertTrue(spy.skipReasons.isEmpty)
        XCTAssertTrue(spy.clickReasons.isEmpty)
    }
}

// MARK: - Offering the control

/// AVKit cannot refuse a start — `canStartPictureInPictureAutomaticallyFromInline`
/// covers automatic entry only, and `willStart` cannot cancel — so under
/// `.suspended` a control left enabled opens the window and has it closed again a
/// moment later. The session answers whether to offer one at all.
@MainActor
final class VASTPictureInPictureOfferTests: XCTestCase {

    private func session(_ policy: VASTAdSession.PictureInPicturePolicy) -> VASTAdSession {
        VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(pictureInPicture: policy)
        )
    }

    func testTheControlIsWithdrawnForTheLengthOfASuspendedBreak() {
        let session = session(.suspended)
        XCTAssertTrue(session.permitsPictureInPicture, "between breaks the window is the host's")

        for state in [VASTAdSession.State.loading, .playing, .paused] {
            session.state = state
            XCTAssertFalse(session.permitsPictureInPicture, "offered during \(state)")
        }

        session.state = .finished(.completed)
        XCTAssertTrue(session.permitsPictureInPicture, "the break is over")
    }

    /// The other two policies mean the ad may be in the window, so withdrawing
    /// the control would be taking away something that works.
    func testTheControlStandsUnderTheOtherPolicies() {
        for policy in [VASTAdSession.PictureInPicturePolicy.pausesAd, .allowed] {
            let session = session(policy)
            session.state = .playing
            XCTAssertTrue(session.permitsPictureInPicture, "withdrawn under \(policy)")
        }
    }
}
