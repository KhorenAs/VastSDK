//
//  VASTParserTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// Fixtures come from the IAB sample tags shipped with dailymotion/vast-client-js
/// (MIT). They are used because they carry the inconsistencies real ad servers
/// produce, which synthetic XML never does.
final class VASTParserTests: XCTestCase {

    private let parser = VASTParser()

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"),
            "missing fixture \(name).xml"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func inLine(_ entry: VASTDocument.Entry) throws -> VASTAd {
        guard case .inLine(let ad) = entry.body else {
            throw XCTSkip("expected an InLine entry")
        }
        return ad
    }

    private func wrapper(_ entry: VASTDocument.Entry) throws -> VASTDocument.Wrapper {
        guard case .wrapper(let wrapper) = entry.body else {
            throw XCTSkip("expected a Wrapper entry")
        }
        return wrapper
    }

    // MARK: - InLine

    func testParsesInLineLinear() throws {
        let document = try parser.parse(try fixture("inline-linear"))
        XCTAssertEqual(document.version, "4.3")
        XCTAssertEqual(document.entries.count, 1)

        let ad = try inLine(document.entries[0])
        XCTAssertEqual(ad.id, "20001")
        XCTAssertEqual(ad.linear.duration, 16)
        XCTAssertEqual(ad.linear.mediaFiles.count, 1)
        XCTAssertEqual(ad.impressions.count, 1)
        XCTAssertEqual(Set(ad.linear.trackingEvents.keys), [
            .start, .firstQuartile, .midpoint, .thirdQuartile, .complete,
        ])
    }

    /// The same document writes some URIs bare and others in CDATA. Both paths
    /// arrive through different delegate callbacks and must produce equal URLs.
    func testReadsURIsFromBothPlainTextAndCDATA() throws {
        let ad = try inLine(try parser.parse(try fixture("inline-linear")).entries[0])

        // <Error>http://example.com/error</Error> — no CDATA
        XCTAssertEqual(ad.errors.first?.absoluteString, "http://example.com/error")
        // <MediaFile><![CDATA[ ... ]]></MediaFile> — CDATA, padded with newlines
        let media = try XCTUnwrap(ad.linear.mediaFiles.first)
        XCTAssertTrue(media.url.absoluteString.hasPrefix("https://"))
        XCTAssertFalse(media.url.absoluteString.contains("\n"))
    }

    /// VAST booleans appear as `1`/`0` in practice, not only `true`/`false`.
    func testParsesNumericBooleanAttributes() throws {
        let ad = try inLine(try parser.parse(try fixture("inline-linear")).entries[0])
        let media = try XCTUnwrap(ad.linear.mediaFiles.first)

        XCTAssertTrue(media.scalable)               // scalable="1"
        XCTAssertTrue(media.maintainAspectRatio)    // maintainAspectRatio="1"
        XCTAssertEqual(media.bitrate, 500)
        XCTAssertEqual(media.minBitrate, 360)
        XCTAssertEqual(media.maxBitrate, 1080)
        XCTAssertEqual(media.delivery, .progressive)
    }

    func testCapturesExtensionsWithoutInterpretingThem() throws {
        let ad = try inLine(try parser.parse(try fixture("inline-linear")).entries[0])
        XCTAssertFalse(ad.extensions.isEmpty)
        XCTAssertFalse(try XCTUnwrap(ad.extensions.first).xml.isEmpty)
    }

    // MARK: - Wrapper

    func testParsesWrapperAndItsAttributes() throws {
        let document = try parser.parse(try fixture("wrapper-a"))
        let wrapper = try wrapper(document.entries[0])

        XCTAssertEqual(wrapper.tagURI.absoluteString, "wrapper-b.xml")
        XCTAssertTrue(wrapper.followAdditionalWrappers, "defaults to true per §3.19")
        XCTAssertFalse(wrapper.allowMultipleAds, "defaults to false per §3.19")
        XCTAssertEqual(wrapper.impressions.count, 1)
        XCTAssertEqual(wrapper.errors.count, 1)
    }

    func testWrapperAdSequenceIsPreserved() throws {
        let document = try parser.parse(try fixture("wrapper-multiple-ads"))
        let sequences = document.entries.map(\.sequence)

        XCTAssertEqual(sequences, [nil, 1, 2, nil])
        XCTAssertTrue(try wrapper(document.entries[0]).allowMultipleAds)
    }

    // MARK: - No ad

    func testEmptyResponseIsNoAdWithRootError() throws {
        let document = try parser.parse(try fixture("empty-no-ad"))

        XCTAssertTrue(document.isNoAd)
        XCTAssertEqual(document.noAdError?.absoluteString, "http://example.com/empty-no-ad")
    }

    // MARK: - Errors

    /// A VAST 1.0 document is well-formed XML under `<VideoAdServingTemplate>`.
    /// Reporting it as a parse error would send the ad server the wrong code.
    func testVAST1DocumentReportsVersionNotSupported() throws {
        XCTAssertThrowsError(try parser.parse(try fixture("outdated-vast"))) { error in
            XCTAssertEqual(error as? VASTError, .versionNotSupported)
            XCTAssertEqual((error as? VASTError)?.rawValue, 102)
        }
    }

    func testMalformedDocumentReportsParseError() throws {
        XCTAssertThrowsError(try parser.parse(try fixture("invalid-xmlfile"))) { error in
            XCTAssertEqual(error as? VASTError, .xmlParsing)
            XCTAssertEqual((error as? VASTError)?.rawValue, 100)
        }
    }

    // MARK: - Offsets

    func testParsesSkipOffsetAsTimestamp() throws {
        let xml = Self.linear(attributes: #"skipoffset="00:00:07.500""#)
        let ad = try inLine(try parser.parse(xml).entries[0])

        XCTAssertEqual(ad.linear.skipOffset, .time(7.5))
        XCTAssertEqual(ad.linear.resolvedSkipOffset(), 7.5)
        XCTAssertTrue(ad.isSkippable)
    }

    func testParsesSkipOffsetAsPercentage() throws {
        let xml = Self.linear(attributes: #"skipoffset="25%""#)
        let ad = try inLine(try parser.parse(xml).entries[0])

        XCTAssertEqual(ad.linear.skipOffset, .percent(25))
        XCTAssertEqual(try XCTUnwrap(ad.linear.resolvedSkipOffset()), 5, accuracy: 0.001)
    }

    func testAdWithoutSkipOffsetIsNotSkippable() throws {
        let ad = try inLine(try parser.parse(Self.linear()).entries[0])
        XCTAssertNil(ad.linear.skipOffset)
        XCTAssertFalse(ad.isSkippable)
    }

    /// `progress` carries an offset and is modelled apart from the quartiles.
    func testProgressEventIsSeparatedFromQuartileEvents() throws {
        let xml = Self.linear(tracking: """
            <Tracking event="start">https://t.test/start</Tracking>
            <Tracking event="progress" offset="00:00:12">https://t.test/p12</Tracking>
            <Tracking event="progress" offset="50%">https://t.test/p50</Tracking>
            """)
        let ad = try inLine(try parser.parse(xml).entries[0])

        XCTAssertEqual(Set(ad.linear.trackingEvents.keys), [.start])
        XCTAssertEqual(ad.linear.progressEvents.count, 2)
        XCTAssertEqual(ad.linear.progressEvents.map(\.offset), [.time(12), .percent(50)])
    }

    func testUnknownTrackingEventIsIgnoredRatherThanFatal() throws {
        let xml = Self.linear(tracking: """
            <Tracking event="start">https://t.test/start</Tracking>
            <Tracking event="somethingTheSpecNeverDefined">https://t.test/x</Tracking>
            """)
        let ad = try inLine(try parser.parse(xml).entries[0])

        XCTAssertEqual(Set(ad.linear.trackingEvents.keys), [.start])
    }

    // MARK: - Synthetic document

    private static func linear(attributes: String = "", tracking: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <VAST version="4.3">
          <Ad id="synthetic">
            <InLine>
              <AdSystem>test</AdSystem>
              <Impression>https://t.test/impression</Impression>
              <Creatives><Creative id="1"><Linear \(attributes)>
                <Duration>00:00:20</Duration>
                <TrackingEvents>\(tracking)</TrackingEvents>
                <MediaFiles>
                  <MediaFile delivery="progressive" type="video/mp4">https://t.test/v.mp4</MediaFile>
                </MediaFiles>
              </Linear></Creative></Creatives>
            </InLine>
          </Ad>
        </VAST>
        """
    }
}
