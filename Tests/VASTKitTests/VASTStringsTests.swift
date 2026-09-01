//
//  VASTStringsTests.swift
//  VASTKitTests
//

import XCTest
@testable import VASTKit

/// A missing key does not fail: `NSLocalizedString` hands back the key itself, so
/// a skip control reading "skip.action" would ship looking like a bug in someone
/// else's app. Every language is checked here rather than only the one the
/// machine happens to be running in.
final class VASTStringsTests: XCTestCase {

    /// Every string the ad surface can put on screen.
    private static let keys = [
        "ad.badge", "ad.badge.pod", "ad.countdown", "skip.action", "skip.countdown",
        "nowplaying.title",
    ]

    func testEveryLanguageCarriesEveryString() throws {
        let languages = try Self.shippedLanguages()
        XCTAssertTrue(languages.contains("en"), "the default localisation has to be there")
        XCTAssertTrue(languages.contains("hy"), "Armenian was the reason for localising at all")

        for language in languages {
            let bundle = try Self.bundle(for: language)
            for key in Self.keys {
                let missing = "◊"
                let value = bundle.localizedString(forKey: key, value: missing, table: nil)
                XCTAssertNotEqual(value, missing, "\(key) is missing from \(language)")
                XCTAssertFalse(value.isEmpty, "\(key) is empty in \(language)")
            }
        }
    }

    /// The placeholders are what turn a translation into a crash or a wrong
    /// number, so they are counted rather than trusted.
    func testPlaceholderCountsMatchAcrossLanguages() throws {
        for key in Self.keys {
            let counts = try Self.shippedLanguages().map { language in
                try Self.bundle(for: language)
                    .localizedString(forKey: key, value: "", table: nil)
                    .components(separatedBy: "%lld").count - 1
            }
            XCTAssertEqual(
                Set(counts).count, 1,
                "\(key) uses a different number of placeholders in different languages"
            )
        }
    }

    /// The lookup itself, through the same path the surface uses.
    func testFormattingSubstitutesTheNumbers() {
        XCTAssertTrue(VASTStrings.format("ad.badge.pod", 2, 3).contains("2"))
        XCTAssertTrue(VASTStrings.format("ad.badge.pod", 2, 3).contains("3"))
        XCTAssertFalse(VASTStrings.format("skip.countdown", 5).contains("%"))
        XCTAssertNotEqual(VASTStrings.text("skip.action"), "skip.action", "the key came back unresolved")
    }

    // MARK: - Helpers

    private static func shippedLanguages() throws -> [String] {
        let urls = try XCTUnwrap(
            VASTStrings.bundle.urls(forResourcesWithExtension: "lproj", subdirectory: nil)
        )
        return urls.map { $0.deletingPathExtension().lastPathComponent }
    }

    private static func bundle(for language: String) throws -> Bundle {
        let url = try XCTUnwrap(VASTStrings.bundle.url(forResource: language, withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }
}
