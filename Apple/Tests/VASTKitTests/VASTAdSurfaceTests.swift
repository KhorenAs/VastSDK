//
//  VASTAdSurfaceTests.swift
//  VASTKitTests
//

import XCTest
import SwiftUI
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// Renders the surface for real. The bug these cover was invisible to logic
/// tests: the probe was correct in isolation and simply never ran, because the
/// view it measured had collapsed to nothing.
@MainActor
final class VASTAdSurfaceTests: XCTestCase {

    private func makeSession() -> VASTAdSession {
        VASTAdSession(player: AVPlayer())
    }

    /// Forces a layout pass so `onAppear` and `GeometryReader` actually run.
    private func render<V: View>(_ view: V, size: CGSize) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        _ = renderer.cgImage
    }

    // MARK: - Presence

    /// Regression: with no ad on screen the surface has nothing to draw, and a
    /// probe attached to that empty content reported neither presence nor size.
    /// Measuring from outside the conditional content is what fixed it.
    func testSurfaceReportsItsSizeEvenWithNoAdOnScreen() {
        let session = makeSession()
        XCTAssertNil(session.surfacePresence.reportedSize)

        render(VASTAdSurface(session: session), size: CGSize(width: 640, height: 360))

        XCTAssertEqual(session.surfacePresence.reportedSize, CGSize(width: 640, height: 360))
        XCTAssertTrue(session.surfacePresence.isUsable)
    }

    func testSurfaceTooSmallForAControlIsDiagnosed() {
        let session = makeSession()
        render(VASTAdSurface(session: session), size: CGSize(width: 20, height: 20))

        XCTAssertFalse(session.surfacePresence.isUsable)
        XCTAssertNotNil(session.surfacePresence.diagnosis)
        XCTAssertTrue(session.surfacePresence.diagnosis?.contains("too small") == true)
    }

    // MARK: - Diagnosis

    /// Regression: a rendered-and-torn-down surface reported itself absent,
    /// because `onDisappear` was being read as "the host removed me". A surface
    /// that has been laid out once stays reported.
    func testSurfaceStaysReportedAfterTeardown() {
        let session = makeSession()
        render(VASTAdSurface(session: session), size: CGSize(width: 320, height: 180))

        XCTAssertEqual(session.surfacePresence.reportedSize, CGSize(width: 320, height: 180))
        XCTAssertTrue(session.surfacePresence.isUsable)
        XCTAssertNil(session.surfacePresence.diagnosis)
    }

    func testNeverLaidOutSurfaceIsDiagnosed() {
        let presence = VASTSurfacePresence()
        XCTAssertNil(presence.reportedSize)
        XCTAssertFalse(presence.isUsable)
        XCTAssertTrue(presence.diagnosis?.contains("never laid out") == true)
    }

    // MARK: - Z ordering

    /// The surface raises its own `zIndex` so a host does not have to remember to
    /// declare it last. Verified by rendering, because `zIndex` is write-only —
    /// there is no way to read the resulting order back.
    func testSurfaceDrawsAboveASiblingDeclaredAfterIt() throws {
        let session = makeSession()
        let stack = ZStack {
            VASTAdSurface(session: session)
                .background(.blue)
            Color.red
        }
        let renderer = ImageRenderer(content: stack.frame(width: 40, height: 40))
        let image = try XCTUnwrap(renderer.cgImage)

        let centre = try XCTUnwrap(Self.centrePixel(of: image))
        XCTAssertGreaterThan(centre.blue, centre.red, "the surface must not be buried by sibling order")
    }

    private static func centrePixel(of image: CGImage) -> (red: Double, blue: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            image,
            in: CGRect(x: -Double(image.width) / 2, y: -Double(image.height) / 2,
                       width: Double(image.width), height: Double(image.height))
        )
        return (red: Double(pixel[0]) / 255, blue: Double(pixel[2]) / 255)
    }
}
