//
//  VASTLoadBudgetTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// `wrapperTimeout` bounds one fetch. Five of them in series is twenty-five
/// seconds, and an ad the viewer waited that long for is not an ad any more.
@MainActor
final class VASTLoadBudgetTests: XCTestCase {

    func testAResponseThatNeverArrivesEndsOnTheBudget() async {
        let session = Self.session(budget: 0.3)
        let started = ProcessInfo.processInfo.systemUptime

        do {
            try await session.load(tag: Self.tag)
            XCTFail("a load that cannot finish has to end anyway")
        } catch {
            XCTAssertEqual(error as? VASTError, .wrapperTimeout, "301 is the code for a chain that did not answer")
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 5, "the budget did not apply — this was the loader's own timeout")
    }

    /// The session has to be usable afterwards: a budget that leaves it stuck in
    /// `.loading` would be worse than the wait it replaced.
    func testTheSessionIsLeftInAFinishedStateAfterTheBudget() async {
        let session = Self.session(budget: 0.3)
        try? await session.load(tag: Self.tag)

        XCTAssertEqual(session.state, .finished(.failed(.wrapperTimeout)))
    }

    /// Zero means no budget, for a host that would rather wait than lose a fill.
    func testABudgetOfZeroDisablesIt() async {
        let session = Self.session(budget: 0)
        let started = ProcessInfo.processInfo.systemUptime

        // The loader answers after a beat, which a budget of 0.1 would have cut.
        try? await session.load(tag: Self.tag)

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThan(elapsed, 0.3, "the load was cut short by a budget that is off")
    }

    // MARK: - Fixtures

    private static let tag = URL(string: "https://ads.test/tag")!

    private static func session(budget: TimeInterval) -> VASTAdSession {
        VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(
                resolutionTimeout: budget,
                restoresPlayerItem: false,
                loader: SlowLoader()
            )
        )
    }
}

/// Answers eventually, and far later than any budget worth setting.
private struct SlowLoader: iVASTResourceLoader {
    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String {
        try await Task.sleep(nanoseconds: 500_000_000)
        return """
        <VAST version="4.3"><Ad id="a"><InLine>
          <AdSystem>slow</AdSystem>
          <Impression><![CDATA[https://ads.test/impression]]></Impression>
          <Creatives><Creative><Linear>
            <Duration>00:00:10</Duration>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile>
            </MediaFiles>
          </Linear></Creative></Creatives>
        </InLine></Ad></VAST>
        """
    }
}
