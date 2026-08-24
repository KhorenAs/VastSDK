//
//  iVASTAdSessionDelegate.swift
//  VASTSDK
//

import Foundation
import VASTCore

/// UIKit/AppKit-facing mirror of the session's published state.
/// SwiftUI hosts can ignore this and observe `VASTAdSession` directly.
@MainActor
public protocol iVASTAdSessionDelegate: AnyObject {

    func session(_ session: VASTAdSession, didStart ad: VASTAd, at position: VASTAdSession.AdPosition)

    /// Playback position, once per tick.
    ///
    /// `duration` is what the player reports, falling back to `<Duration>` until
    /// it does — the declared value is advisory and the two often disagree.
    /// SwiftUI hosts can read `remainingTime` instead of implementing this.
    func session(
        _ session: VASTAdSession,
        ad: VASTAd,
        didProgressTo time: TimeInterval,
        duration: TimeInterval
    )

    /// `skipoffset` elapsed — draw the skip control now.
    func session(_ session: VASTAdSession, skipDidBecomeAvailableFor ad: VASTAd)

    func session(_ session: VASTAdSession, didFinish ad: VASTAd, outcome: VASTAdSession.Outcome)

    /// One ad failed. A pod continues with the next ad or a stand-alone substitute.
    func session(_ session: VASTAdSession, didFail error: VASTError, for ad: VASTAd?)

    func sessionDidFinishAllAds(_ session: VASTAdSession)

    /// The SDK owns the skip control for this ad but cannot show it: the surface
    /// is missing or too small. Occlusion by another view is not detectable, so
    /// this catches what it can rather than everything.
    func session(_ session: VASTAdSession, skipControlUnavailableFor ad: VASTAd, reason: String)
}

public extension iVASTAdSessionDelegate {
    func session(_ session: VASTAdSession, didStart ad: VASTAd, at position: VASTAdSession.AdPosition) {}
    func session(
        _ session: VASTAdSession,
        ad: VASTAd,
        didProgressTo time: TimeInterval,
        duration: TimeInterval
    ) {}
    func session(_ session: VASTAdSession, skipDidBecomeAvailableFor ad: VASTAd) {}
    func session(_ session: VASTAdSession, didFinish ad: VASTAd, outcome: VASTAdSession.Outcome) {}
    func session(_ session: VASTAdSession, didFail error: VASTError, for ad: VASTAd?) {}
    func sessionDidFinishAllAds(_ session: VASTAdSession) {}
    func session(_ session: VASTAdSession, skipControlUnavailableFor ad: VASTAd, reason: String) {}
}
