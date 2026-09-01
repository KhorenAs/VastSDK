//
//  VASTAdSession.State.swift
//  VASTSDK
//

import Foundation
import VASTCore

public extension VASTAdSession {

    enum State: Sendable, Equatable {
        case idle
        case loading
        case playing
        case paused
        case finished(Outcome)
    }

    enum Outcome: Sendable, Equatable {
        case completed
        case skipped
        case failed(VASTError)
    }

    struct AdPosition: Sendable, Equatable {
        public let index: Int
        public let total: Int

        public static let single = AdPosition(index: 1, total: 1)
        public var isPod: Bool { total > 1 }
    }

    /// Raised when work is abandoned because the host stopped the session, as
    /// distinct from anything going wrong with the response.
    enum SessionError: Error, Sendable, Equatable {
        case stopped
    }

    enum SkipError: Error, Sendable, Equatable {
        case noActiveAd
        case notSkippable
        case notYetAvailable(after: TimeInterval)
    }
}
