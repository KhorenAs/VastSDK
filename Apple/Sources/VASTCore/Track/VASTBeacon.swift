//
//  VASTBeacon.swift
//  VASTSDK
//

import Foundation

/// A tracking request the engine decided should be sent.
///
/// The engine returns these rather than performing IO, so tests assert on plain
/// values instead of mocking a network layer.
public struct VASTBeacon: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        case impression
        case tracking(VASTAd.TrackingEvent)
        case progress(TimeInterval)
        case clickTracking
        case error(VASTError)
        /// A verification vendor asked to observe this ad and nothing ran its
        /// code (§3.16). Silence would let the vendor count the session as
        /// measured, so the reason is reported rather than withheld.
        case verificationNotExecuted(VASTAd.Verification.NotExecutedReason)
    }

    public let kind: Kind
    public let url: URL
    public let adID: String

    public init(kind: Kind, url: URL, adID: String) {
        self.kind = kind
        self.url = url
        self.adID = adID
    }
}
