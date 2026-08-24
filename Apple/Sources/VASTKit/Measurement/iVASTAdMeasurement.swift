//
//  iVASTAdMeasurement.swift
//  VASTSDK
//

import Foundation
import VASTCore

/// Where third-party measurement plugs in.
///
/// The SDK parses `<AdVerifications>` and never executes it: running a vendor's
/// code means the IAB Open Measurement SDK, which is licensed separately, ships
/// as a namespaced binary, and brings a WebView with it. None of that belongs in
/// a package whose core cannot even import AVFoundation — so this protocol is the
/// seam, and an implementation lives outside.
///
/// Supplying one changes what the SDK reports. With no measurement configured,
/// every vendor is told `verificationNotExecuted`, because that is the truth.
/// With one configured the SDK goes quiet and the implementation owns the
/// reporting, including telling the session when a resource failed to load —
/// `resourceLoadError` can only be known by whoever tried.
@MainActor
public protocol iVASTAdMeasurement: AnyObject {

    /// One ad is about to be shown. Called before the impression.
    func begin(_ context: VASTMeasurementContext)

    /// Playback reached something a measurement vendor cares about.
    func record(_ event: VASTMeasurementEvent)

    /// The ad is over, by any route. Called exactly once per `begin`.
    func finish()

    /// The OMID partner name and version, as the vendor's script sees it, for the
    /// `[OMIDPARTNER]` macro. Defaults to `nil`, which reports it as unknown —
    /// honest for an integration that is not OMID.
    var omidPartner: String? { get }
}

public extension iVASTAdMeasurement {
    var omidPartner: String? { nil }
}

/// What an implementation needs to open a measurement session.
@MainActor
public struct VASTMeasurementContext {

    public let ad: VASTAd
    /// Convenience for `ad.adVerifications`, which is what this exists for.
    public var verifications: [VASTAd.Verification] { ad.adVerifications }
    /// The view the creative is being shown in, when the SDK knows it — the
    /// container from `attach(to:)`. A SwiftUI host owns its own player view, so
    /// this is `nil` there until the host says otherwise.
    public let adView: PlatformView?

    public init(ad: VASTAd, adView: PlatformView?) {
        self.ad = ad
        self.adView = adView
    }
}

/// Modelled as one value type rather than a method per event so that the
/// *sequence* can be asserted in a test. Measurement integrations fail on order
/// far more often than on any single call.
public enum VASTMeasurementEvent: Sendable, Equatable {
    case impression
    case start(duration: TimeInterval, isMuted: Bool)
    /// `firstQuartile`, `midpoint`, `thirdQuartile` or `complete`.
    case quartile(VASTAd.TrackingEvent)
    case progress(TimeInterval)
    case pause
    case resume
    case skipped
    case clicked
    case failed(VASTError)
}
