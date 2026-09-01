//
//  VASTComplianceTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// A loader that answers from memory, so a session can be driven with no network.
private struct StubLoader: iVASTResourceLoader {
    let xml: String
    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String { xml }
}

/// Records what was fired instead of sending it.
private final actor RecordingTransport: iVASTBeaconTransport {
    private(set) var beacons: [VASTBeacon] = []
    func fire(_ beacons: [VASTBeacon]) async { self.beacons += beacons }
    func recorded() async -> [VASTBeacon] { beacons }
}

@MainActor
final class VASTComplianceTests: XCTestCase {

    private func response(skipOffset: String?) -> String {
        let skip = skipOffset.map { #" skipoffset="\#($0)""# } ?? ""
        return """
        <VAST version="4.3"><Ad id="a"><InLine>
          <AdSystem>test</AdSystem>
          <Error><![CDATA[https://ads.test/error?code=[ERRORCODE]]]></Error>
          <Impression><![CDATA[https://ads.test/impression]]></Impression>
          <Creatives><Creative><Linear\(skip)>
            <Duration>00:00:20</Duration>
            <MediaFiles><MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile></MediaFiles>
          </Linear></Creative></Creatives>
        </InLine></Ad></VAST>
        """
    }

    private func session(
        skipOffset: String?,
        skipPresentation: VASTAdSession.SkipPresentation,
        transport: RecordingTransport
    ) -> VASTAdSession {
        VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(
                restoresPlayerItem: false,
                skipPresentation: skipPresentation,
                transport: transport,
                loader: StubLoader(xml: response(skipOffset: skipOffset))
            )
        )
    }

    // MARK: - §2.3

    /// "nor should the media player play the Skippable Ad as a Linear Ad
    /// (without skip controls)". A host that cannot offer the control must get a
    /// refusal, not a silently non-compliant impression.
    func testSkippableAdIsRefusedWhenNoSkipControlCanBeOffered() async throws {
        let transport = RecordingTransport()
        let session = session(
            skipOffset: "00:00:05",
            skipPresentation: .unsupported,
            transport: transport
        )

        try await session.load(tag: URL(string: "https://ads.test/tag")!)
        let outcome = await session.play()

        XCTAssertEqual(outcome, .failed(.trafficking))
        XCTAssertEqual(VASTError.trafficking.rawValue, 200)

        // The ad server is told why, on the URI it supplied for the purpose.
        let fired = await transport.recorded()
        XCTAssertTrue(
            fired.contains { $0.kind == .error(.trafficking) },
            "the refusal must be reported, not silent"
        )
        XCTAssertFalse(
            fired.contains { $0.kind == .impression },
            "an ad that was refused was never shown"
        )
    }

    /// A non-skippable ad is unaffected: there is no skip control owed.
    func testNonSkippableAdIsUnaffectedBySkipPresentation() async throws {
        let transport = RecordingTransport()
        let session = session(
            skipOffset: nil,
            skipPresentation: .unsupported,
            transport: transport
        )

        try await session.load(tag: URL(string: "https://ads.test/tag")!)
        let outcome = await session.play()

        // The creative URL is unreachable in a test, so playback fails on the
        // media rather than on compliance — which is the distinction being made.
        XCTAssertNotEqual(outcome, .failed(.trafficking))
    }

    /// Declaring that the host draws the control is enough to let the ad play.
    func testSkippableAdIsAllowedWhenTheHostOwnsTheControl() async throws {
        let transport = RecordingTransport()
        let session = session(
            skipOffset: "00:00:05",
            skipPresentation: .host,
            transport: transport
        )

        try await session.load(tag: URL(string: "https://ads.test/tag")!)
        let outcome = await session.play()

        XCTAssertNotEqual(outcome, .failed(.trafficking))
    }

    // MARK: - Defaults

    /// A host that configures nothing gets the compliant behaviour.
    func testDefaultConfigurationIsCompliant() {
        let configuration = VASTAdSession.Configuration()
        XCTAssertEqual(configuration.skipPresentation, .sdk)
        XCTAssertEqual(configuration.clickPresentation, .surface)
        XCTAssertEqual(configuration.maxWrapperDepth, 5, "§3.19.1 requires at least five")
    }

    // MARK: - Skip guard

    func testSkipOnANonSkippableAdThrows() async throws {
        let transport = RecordingTransport()
        let session = session(skipOffset: nil, skipPresentation: .sdk, transport: transport)
        try await session.load(tag: URL(string: "https://ads.test/tag")!)

        XCTAssertThrowsError(try session.skip()) { error in
            // No ad is on screen yet, so the guard reports that first.
            XCTAssertEqual(error as? VASTAdSession.SkipError, .noActiveAd)
        }
    }
}
