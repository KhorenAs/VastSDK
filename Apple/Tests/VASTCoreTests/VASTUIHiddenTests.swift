//
//  VASTUIHiddenTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// `VASTAd.isUIHidden` is read straight out of the response, so it is tested the
/// way a response arrives: as XML through the parser, not as a hand-built model.
final class VASTUIHiddenTests: XCTestCase {

    // MARK: - Reading the key

    func testTheKeyIsReadFromTheResponse() throws {
        let ad = try Self.ad(uiSettings: "<UiHidden>1</UiHidden>")
        XCTAssertTrue(ad.isUIHidden)
    }

    /// The live AdFox tag sends `UiHideable`; `UiHidden` is the other spelling in
    /// the same family. A tag using the one the SDK did not read would be drawn
    /// with the wrong UI and never say so.
    func testBothSpellingsAreRead() throws {
        for key in ["UiHidden", "UiHideable"] {
            let ad = try Self.ad(uiSettings: "<\(key)>1</\(key)>")
            XCTAssertTrue(ad.isUIHidden, "\(key) was not read")
        }
    }

    /// Presence is the request the vendor intends, so an element carrying no text
    /// still counts.
    func testAnEmptyElementStillAsksForIt() throws {
        XCTAssertTrue(try Self.ad(uiSettings: "<UiHidden/>").isUIHidden)
        XCTAssertTrue(try Self.ad(uiSettings: "<UiHidden></UiHidden>").isUIHidden)
    }

    /// Servers wrap extension values in CDATA about as often as not.
    func testACDATAValueIsRead() throws {
        XCTAssertTrue(try Self.ad(uiSettings: "<UiHidden><![CDATA[1]]></UiHidden>").isUIHidden)
        XCTAssertFalse(try Self.ad(uiSettings: "<UiHidden><![CDATA[0]]></UiHidden>").isUIHidden)
    }

    /// A server sending `0` means "keep your UI", and inverting that would be
    /// worse than not reading the key at all.
    func testAnExplicitlyNegativeValueIsHonoured() throws {
        for value in ["0", "false", "NO"] {
            let ad = try Self.ad(uiSettings: "<UiHidden>\(value)</UiHidden>")
            XCTAssertFalse(ad.isUIHidden, "\(value) was read as yes")
        }
    }

    // MARK: - What it must not read

    func testAResponseWithoutTheExtensionAsksForNothing() throws {
        XCTAssertFalse(try Self.ad(uiSettings: nil).isUIHidden)
    }

    /// Another vendor's extension is not this one, whatever it happens to contain.
    func testTheKeyIsIgnoredOutsideUISettings() throws {
        let xml = Self.response(
            extensions: #"<Extension type="somethingElse"><UiHidden>1</UiHidden></Extension>"#
        )
        XCTAssertFalse(try Self.parse(xml).isUIHidden)
    }

    /// The raw XML is still handed over untouched (§3.18) — interpreting one key
    /// must not mean consuming the extension it came from.
    func testTheExtensionIsStillHandedOverRaw() throws {
        let ad = try Self.ad(uiSettings: "<UiHideable>1</UiHideable>")
        let vendor = try XCTUnwrap(ad.extensions.first { $0.type == "uiSettings" })
        XCTAssertTrue(vendor.xml.contains("UiHideable"))
        XCTAssertEqual(vendor.value(of: "UiHideable"), "1")
    }
}

// MARK: - Fixtures

private extension VASTUIHiddenTests {

    static func ad(uiSettings: String?) throws -> VASTAd {
        let element = uiSettings.map { #"<Extension type="uiSettings">\#($0)</Extension>"# }
        return try parse(response(extensions: element))
    }

    static func response(extensions: String?) -> String {
        let block = extensions.map { "<Extensions>\($0)</Extensions>" } ?? ""
        return """
        <VAST version="4.3"><Ad id="a"><InLine>
          <AdSystem>test</AdSystem>
          <Impression><![CDATA[https://ads.test/impression]]></Impression>
          <Creatives><Creative><Linear>
            <Duration>00:00:20</Duration>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile>
            </MediaFiles>
          </Linear></Creative></Creatives>
          \(block)
        </InLine></Ad></VAST>
        """
    }

    static func parse(_ xml: String) throws -> VASTAd {
        let document = try VASTParser().parse(xml)
        guard case .inLine(let ad) = try XCTUnwrap(document.entries.first).body else {
            return try XCTUnwrap(nil as VASTAd?)
        }
        return ad
    }
}
