//
//  VASTSurfacePresence.swift
//  VASTSDK
//

import Foundation
import CoreGraphics

/// What the session knows about its ad surface actually being on screen.
///
/// `SkipPresentation.sdk` promises a skippable ad will be offered a skip control
/// (§2.3). The surface raises its own `zIndex`, so sibling order cannot bury it.
/// What is left to detect is a host that never composed the surface at all, or
/// gave it no room — both visible here. A host that deliberately raises something
/// above the ad is not: SwiftUI does not expose occlusion, and that case is a
/// decision rather than a mistake.
///
/// Judged only when the control is actually due, several seconds into playback.
/// Asking earlier cannot distinguish "missing" from "not laid out yet", and
/// guessing produced a false alarm that crashed a host doing nothing wrong.
public struct VASTSurfacePresence: Sendable, Equatable {

    /// Below this in either dimension there is nowhere to put a usable control.
    static let minimumUsableEdge: CGFloat = 44

    /// The size the surface last reported, or `nil` if it never has.
    public private(set) var reportedSize: CGSize?
    /// The size of the skip control itself, once it has been drawn. Distinct from
    /// the surface: a full-size surface can still carry a control of no size.
    public private(set) var skipControlSize: CGSize?

    public var isUsable: Bool {
        guard let reportedSize else { return false }
        return reportedSize.width >= Self.minimumUsableEdge
            && reportedSize.height >= Self.minimumUsableEdge
    }

    /// `nil` while the control has not been drawn — which is not the same as too
    /// small, and must not be reported as if it were.
    public var skipControlIsUsable: Bool? {
        guard let skipControlSize else { return nil }
        return skipControlSize.width >= Self.minimumUsableEdge
            && skipControlSize.height >= Self.minimumUsableEdge
    }

    mutating func update(size: CGSize) {
        reportedSize = size
    }

    mutating func update(skipControlSize size: CGSize) {
        skipControlSize = size
    }

    /// Why the surface cannot carry a control, in words a developer can act on.
    var diagnosis: String? {
        guard let reportedSize else {
            return """
            VASTAdSurface was never laid out, so the skip control this ad \
            requires cannot be shown. Compose VASTAdSurface over your player \
            view, or set Configuration.skipPresentation to .host or .unsupported.
            """
        }
        guard !isUsable else { return nil }
        return """
        VASTAdSurface is \(Int(reportedSize.width))×\(Int(reportedSize.height))pt, \
        too small to carry a skip control. Give it the player's bounds rather \
        than wrapping it in a sized container.
        """
    }

    /// Why the control that *was* drawn cannot be used. Silent while it has not
    /// been drawn yet: `diagnosis` already covers a surface that never appeared,
    /// and guessing early is what produced a false alarm before.
    var skipControlDiagnosis: String? {
        guard let size = skipControlSize, skipControlIsUsable == false else { return nil }
        return """
        The skip control drew at \(Int(size.width))×\(Int(size.height))pt, too \
        small for a viewer to hit. A vastSkipButton builder that returns an empty \
        or unsized view leaves a skippable ad with no way to skip it.
        """
    }
}
