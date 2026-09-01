//
//  DemoSettings.swift
//  VASTDemo
//

import Foundation
import Combine
import VASTKit

/// Settings a scenario is opened *with*, rather than settings it can be changed
/// to while it runs.
///
/// `VASTAdSession.Configuration` is fixed once the session exists — the policy an
/// ad break runs under cannot change halfway through the break — so the choice
/// belongs on the list screen, before a player screen is built. Both demos read
/// it, so the two hosts stay comparable behaviour for behaviour.
@MainActor
final class DemoSettings: ObservableObject {

    static let shared = DemoSettings()

    /// Held as an index rather than as the policy itself. A SwiftUI `Picker` tag
    /// and a `UISegmentedControl` both want something a policy is not — the SDK's
    /// enum is `Equatable`, not `Hashable`, and a segment is an integer either
    /// way — so the index is the one shape both hosts can use unchanged.
    @Published var pictureInPictureIndex = 0

    var pictureInPicture: VASTAdSession.PictureInPicturePolicy {
        Self.pictureInPicturePolicies[pictureInPictureIndex]
    }

    /// The SDK's default first, so index zero and the default agree.
    static let pictureInPicturePolicies: [VASTAdSession.PictureInPicturePolicy] =
        [.allowed, .pausesAd, .suspended]

    static let pictureInPictureLabels = ["Allow", "Pause ad", "Suspend"]
}
