//
//  VASTMediaFileSelectorTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// Selection is a ranking rather than a filter wherever the spec allows it: an ad
/// with one poorly-fitting media file should still play, because a no-fill costs
/// the advertiser a delivery while a slightly-too-large file costs a little
/// bandwidth.
final class VASTMediaFileSelectorTests: XCTestCase {

    private let selector = VASTMediaFileSelector()

    // MARK: - Transport security

    /// A response offering both renditions used to have the http one chosen on
    /// merit and then fail under App Transport Security — reported as a media
    /// error, which tells the ad server the creative was broken rather than that
    /// the player refused to fetch it.
    func testHTTPSIsPreferredOverAnOtherwiseIdenticalHTTPFile() throws {
        let chosen = try selector.select(
            from: [
                Self.file("http://ads.test/a.mp4", width: 854, height: 480),
                Self.file("https://ads.test/a.mp4", width: 854, height: 480),
            ],
            capabilities: Self.capabilities
        )
        XCTAssertEqual(chosen.url.scheme, "https")
    }

    /// The preference is small on purpose: it decides between otherwise equal
    /// files, and does not hand a viewer a 4K creative over a well-fitting one.
    func testTheHTTPSPreferenceDoesNotOverrideAMuchBetterFit() throws {
        let chosen = try selector.select(
            from: [
                Self.file("http://ads.test/fits.mp4", width: 854, height: 480),
                Self.file("https://ads.test/huge.mp4", width: 3840, height: 2160),
            ],
            capabilities: Self.capabilities
        )
        XCTAssertEqual(chosen.url.lastPathComponent, "fits.mp4")
    }

    /// And an http-only response still plays: refusing it would be the SDK
    /// deciding the advertiser loses the delivery.
    func testAnHTTPOnlyResponseIsStillPlayed() throws {
        let chosen = try selector.select(
            from: [Self.file("http://ads.test/only.mp4", width: 854, height: 480)],
            capabilities: Self.capabilities
        )
        XCTAssertEqual(chosen.url.lastPathComponent, "only.mp4")
    }

    // MARK: - Fit

    func testTheClosestResolutionWins() throws {
        let chosen = try selector.select(
            from: [
                Self.file("https://ads.test/small.mp4", width: 320, height: 180),
                Self.file("https://ads.test/right.mp4", width: 1280, height: 720),
                Self.file("https://ads.test/huge.mp4", width: 3840, height: 2160),
            ],
            capabilities: VASTMediaFileSelector.Capabilities(width: 1280, height: 720)
        )
        XCTAssertEqual(chosen.url.lastPathComponent, "right.mp4")
    }

    /// Being too small is the more visible defect — a player can downscale
    /// cleanly and cannot invent detail — so the penalty for undershooting rises
    /// twice as fast as the one for overshooting.
    ///
    /// A slope, note, and not a value: half size and double size come out exactly
    /// equal, which is what "twice as fast" means once the arithmetic is done.
    /// The test therefore compares two files the same distance from a perfect fit.
    func testUndershootingIsPenalisedMoreThanOvershooting() throws {
        let chosen = try selector.select(
            from: [
                Self.file("https://ads.test/under.mp4", width: 960, height: 540),
                Self.file("https://ads.test/over.mp4", width: 1600, height: 900),
            ],
            capabilities: VASTMediaFileSelector.Capabilities(width: 1280, height: 720)
        )
        XCTAssertEqual(chosen.url.lastPathComponent, "over.mp4")
    }

    /// Half and double really are equal, so the response's own order decides.
    /// Worth pinning: it is the reason a list's first entry can win outright.
    func testEqualDistanceLeavesTheResponseOrderToDecide() throws {
        let files = [
            Self.file("https://ads.test/half.mp4", width: 640, height: 360),
            Self.file("https://ads.test/double.mp4", width: 2560, height: 1440),
        ]
        let capabilities = VASTMediaFileSelector.Capabilities(width: 1280, height: 720)

        XCTAssertEqual(try selector.select(from: files, capabilities: capabilities)
            .url.lastPathComponent, "half.mp4")
        XCTAssertEqual(try selector.select(from: files.reversed(), capabilities: capabilities)
            .url.lastPathComponent, "double.mp4")
    }

    // MARK: - What is refused

    /// An unplayable container is refused outright: playing it would produce 403
    /// anyway, and one file the player cannot decode must not lose the ad when
    /// another can.
    func testAnUndecodableContainerIsSkippedRatherThanChosen() throws {
        let chosen = try selector.select(
            from: [
                Self.file("https://ads.test/flash.flv", type: "video/x-flv", width: 1280, height: 720),
                Self.file("https://ads.test/ok.mp4", width: 320, height: 180),
            ],
            capabilities: VASTMediaFileSelector.Capabilities(width: 1280, height: 720)
        )
        XCTAssertEqual(chosen.url.lastPathComponent, "ok.mp4")
    }

    func testNothingPlayableIsReportedAs403() {
        XCTAssertThrowsError(
            try selector.select(
                from: [Self.file("https://ads.test/x.flv", type: "video/x-flv")],
                capabilities: Self.capabilities
            )
        ) { error in
            XCTAssertEqual(error as? VASTError, .noSupportedMediaFile)
            XCTAssertEqual(VASTError.noSupportedMediaFile.rawValue, 403)
        }
    }

    /// A platform with no streaming pipeline cannot take a streaming delivery,
    /// however well it fits.
    func testStreamingIsRefusedWhereItCannotBePlayed() throws {
        var capabilities = Self.capabilities
        capabilities.supportsStreaming = false

        let chosen = try selector.select(
            from: [
                Self.file("https://ads.test/live.m3u8", type: "application/x-mpegurl",
                          delivery: .streaming, width: 1280, height: 720),
                Self.file("https://ads.test/file.mp4", width: 320, height: 180),
            ],
            capabilities: capabilities
        )
        XCTAssertEqual(chosen.url.lastPathComponent, "file.mp4")
    }

    // MARK: - Fixtures

    private static let capabilities = VASTMediaFileSelector.Capabilities(width: 1280, height: 720)

    private static func file(
        _ url: String,
        type: String = "video/mp4",
        delivery: VASTAd.Delivery = .progressive,
        width: Int? = nil,
        height: Int? = nil
    ) -> VASTAd.MediaFile {
        VASTAd.MediaFile(
            id: nil,
            url: URL(string: url)!,
            mimeType: type,
            delivery: delivery,
            width: width,
            height: height,
            bitrate: nil,
            minBitrate: nil,
            maxBitrate: nil,
            scalable: true,
            maintainAspectRatio: true,
            codec: nil
        )
    }
}
