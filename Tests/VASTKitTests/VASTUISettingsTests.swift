//
//  VASTUISettingsTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// `<Extension type="uiSettings">` lets a response ask the player to draw no UI
/// of its own. It is a vendor convention, not specification, so the rule that
/// matters most here is the one about who is allowed to trigger it.
@MainActor
final class VASTUISettingsTests: XCTestCase {

    // MARK: - Who decides

    /// The response alone is not enough. A vendor key that could suppress the ad
    /// UI on its own would be a vendor deciding whether the host honours §2.3.
    func testAResponseCannotHideTheUIOnItsOwn() {
        let session = VASTAdSession(player: AVPlayer())
        session.currentAd = Self.ad(uiSettings: "<UiHidden>1</UiHidden>")

        XCTAssertFalse(session.isHiddenUi, "the default has to be the compliant one")
        XCTAssertFalse(
            session.suppressesAdUI,
            "the response hid the ad UI without the host ever allowing it"
        )
    }

    /// The permission alone is not enough either: a host that can draw its own UI
    /// still shows the SDK's for every response that did not ask.
    func testPermissionAloneChangesNothing() {
        let session = VASTAdSession(player: AVPlayer())
        session.isHiddenUi = true
        session.currentAd = Self.ad(uiSettings: nil)

        XCTAssertFalse(session.suppressesAdUI)
    }

    func testPermissionAndRequestTogetherSuppressTheAdUI() {
        let session = VASTAdSession(player: AVPlayer())
        session.isHiddenUi = true
        session.currentAd = Self.ad(uiSettings: "<UiHidden>1</UiHidden>")

        XCTAssertTrue(session.suppressesAdUI)
    }

    /// Nothing is playing, so there is nothing to hide.
    func testNoAdMeansNothingIsSuppressed() {
        let session = VASTAdSession(player: AVPlayer())
        session.isHiddenUi = true

        XCTAssertFalse(session.suppressesAdUI)
    }

    // MARK: - Reading the key

    /// The live AdFox tag sends `UiHideable`; `UiHidden` is the other spelling in
    /// the same family. A tag that used the one the SDK did not read would be
    /// drawn with the wrong UI and never say so.
    func testBothSpellingsAreRead() {
        for key in ["UiHidden", "UiHideable"] {
            let session = VASTAdSession(player: AVPlayer())
            session.isHiddenUi = true
            session.currentAd = Self.ad(uiSettings: "<\(key)>1</\(key)>")

            XCTAssertTrue(session.suppressesAdUI, "\(key) was not read")
        }
    }

    /// Presence is the signal the vendor intends, so a self-closing element with
    /// no text still counts.
    func testAnEmptyElementStillAsksForIt() {
        let session = VASTAdSession(player: AVPlayer())
        session.isHiddenUi = true
        session.currentAd = Self.ad(uiSettings: "<UiHidden/>")

        XCTAssertTrue(session.suppressesAdUI)
    }

    /// A server that sends `0` means "keep your UI", and inverting that would be
    /// worse than not reading the key at all.
    func testAnExplicitlyNegativeValueIsHonoured() {
        for value in ["0", "false", "NO"] {
            let session = VASTAdSession(player: AVPlayer())
            session.isHiddenUi = true
            session.currentAd = Self.ad(uiSettings: "<UiHidden>\(value)</UiHidden>")

            XCTAssertFalse(session.suppressesAdUI, "\(value) was read as yes")
        }
    }

    /// Another vendor's extension is not this one.
    func testAnUnrelatedExtensionIsLeftAlone() {
        let session = VASTAdSession(player: AVPlayer())
        session.isHiddenUi = true
        session.currentAd = VASTAdSession.testAd(
            extensions: [.init(type: "AdVerifications", xml: "<UiHidden>1</UiHidden>")]
        )

        XCTAssertFalse(session.suppressesAdUI, "a UiHidden outside uiSettings was acted on")
    }

    // MARK: - §2.3

    /// Suppressing the UI takes the skip control off the screen. If the host did
    /// not also take the control over, the promise `.sdk` makes is broken and the
    /// host has to hear about it.
    func testHidingTheUIWithoutTakingTheSkipControlIsReported() {
        let recorder = DelegateRecorder()
        let session = VASTAdSession(player: AVPlayer())
        session.delegate = recorder
        session.isHiddenUi = true

        let ad = Self.ad(uiSettings: "<UiHidden>1</UiHidden>", skipOffset: .time(5))
        session.currentAd = ad
        session.verifyHostDrawnUI(for: ad)

        XCTAssertEqual(recorder.skipControlComplaints, 1)
    }

    /// The host took the control over, which is what it is meant to do here.
    func testHidingTheUIUnderHostSkipPresentationIsSilent() {
        let recorder = DelegateRecorder()
        let session = VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(skipPresentation: .host)
        )
        session.delegate = recorder
        session.isHiddenUi = true

        let ad = Self.ad(uiSettings: "<UiHidden>1</UiHidden>", skipOffset: .time(5))
        session.currentAd = ad
        session.verifyHostDrawnUI(for: ad)

        XCTAssertEqual(recorder.skipControlComplaints, 0)
    }

    /// Nothing is owed on a non-skippable ad, so hiding everything is fine.
    func testHidingTheUIOnANonSkippableAdIsSilent() {
        let recorder = DelegateRecorder()
        let session = VASTAdSession(player: AVPlayer())
        session.delegate = recorder
        session.isHiddenUi = true

        let ad = Self.ad(uiSettings: "<UiHidden>1</UiHidden>")
        session.currentAd = ad
        session.verifyHostDrawnUI(for: ad)

        XCTAssertEqual(recorder.skipControlComplaints, 0)
    }
}

// MARK: - Fixtures

private extension VASTUISettingsTests {

    static func ad(uiSettings: String?, skipOffset: VASTAd.SkipOffset? = nil) -> VASTAd {
        VASTAdSession.testAd(
            skipOffset: skipOffset,
            extensions: uiSettings.map { [.init(type: "uiSettings", xml: $0)] } ?? []
        )
    }
}

extension VASTAdSession {

    /// A minimal ad, so a test can set `currentAd` without running a break.
    static func testAd(
        skipOffset: VASTAd.SkipOffset? = nil,
        extensions: [VASTAd.Extension] = []
    ) -> VASTAd {
        VASTAd(
            id: "a",
            sequence: nil,
            adSystem: "test",
            title: "test",
            linear: VASTAd.Linear(duration: 20, skipOffset: skipOffset),
            impressions: [],
            errors: [],
            extensions: extensions
        )
    }
}

private final class DelegateRecorder: iVASTAdSessionDelegate {
    private(set) var skipControlComplaints = 0

    func session(_ session: VASTAdSession, skipControlUnavailableFor ad: VASTAd, reason: String) {
        skipControlComplaints += 1
    }
}
