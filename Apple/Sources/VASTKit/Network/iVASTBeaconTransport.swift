//
//  iVASTBeaconTransport.swift
//  VASTSDK
//

import Foundation
import VASTCore

/// Sends the beacons the engine produced. Fire-and-forget: a tracking failure
/// must never interrupt playback.
public protocol iVASTBeaconTransport: Sendable {
    func fire(_ beacons: [VASTBeacon]) async
}
