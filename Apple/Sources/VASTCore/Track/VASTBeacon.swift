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
