//
//  DemoNowPlaying.swift
//  VASTDemo
//

import Foundation
import AVFoundation
import MediaPlayer

/// The host's half of the system transport: what Control Centre, the lock
/// screen and AirPods show for the *content*, and what their buttons do.
///
/// A demo needs this to be worth looking at. The SDK borrows these controls for
/// the length of a break — taking the seek controls away and naming the ad — and
/// with nothing published to borrow, there is nothing to watch it give back.
///
/// Deliberately does not publish while the ad session owns the player. Two
/// writers on one `MPNowPlayingInfoCenter` is the mistake this class exists to
/// demonstrate the absence of: the host's periodic update would overwrite the
/// ad's title a fraction of a second after the SDK set it.
@MainActor
final class DemoNowPlaying {

    private let player: AVPlayer
    private let title: String

    /// Set while the break runs, the same way `ContentPlayerModel.isSuspended`
    /// is: the transport belongs to the SDK for that stretch.
    var isSuspended = false {
        didSet { if !isSuspended { publish() } }
    }

    private var targets: [(MPRemoteCommand, Any)] = []
    private var statusObservation: NSKeyValueObservation?

    init(player: AVPlayer, title: String) {
        self.player = player
        self.title = title
    }

    func activate() {
        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { [weak self] in self?.player.play() }
        add(center.pauseCommand) { [weak self] in self?.player.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            player.rate > 0 ? player.pause() : player.play()
        }

        // The one worth watching. Enabled here, taken away by the SDK for the
        // break, and handed back when it ends.
        center.changePlaybackPositionCommand.isEnabled = true
        let seek = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, seek))

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { [weak self] in self?.step(by: 10) }
        add(center.skipBackwardCommand) { [weak self] in self?.step(by: -10) }

        // Republished on every transition rather than on a timer: the system
        // runs its own clock from the elapsed time and rate it was last given.
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.publish() }
        }
        publish()
    }

    /// Targets are removed by hand. A screen that is left and re-entered would
    /// otherwise stack a second set of handlers on the shared command centre,
    /// each holding a player nobody is watching.
    func invalidate() {
        statusObservation?.invalidate()
        statusObservation = nil
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            MainActor.assumeIsolated { action() }
            return .success
        }
        targets.append((command, target))
    }

    private func step(by seconds: TimeInterval) {
        let target = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600))
    }

    private func publish() {
        guard !isSuspended else { return }
        let duration = player.currentItem?.duration ?? .indefinite
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "VAST Demo",
            MPMediaItemPropertyPlaybackDuration: duration.isNumeric ? duration.seconds : 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
    }
}
