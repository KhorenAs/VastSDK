//
//  VASTNowPlayingController.swift
//  VASTSDK
//

import Foundation
import MediaPlayer
import VASTCore

/// Holds the system's Now Playing controls for the length of an ad break, and
/// hands them back exactly as they were found.
///
/// These controls exist at all because the SDK's other window does: Picture in
/// Picture needs the `audio` background mode and an active `.playback` session,
/// and those are what make an app the Now Playing app. Control Centre, the lock
/// screen, AirPods and CarPlay then offer a transport for whatever is on the
/// player — which, during a break, is the creative.
///
/// The seeking half of that transport is the same problem the window's scrubber
/// was, with the same answer: VAST defines nothing that would permit a jump
/// inside a linear creative, and the tracking engine treats one as unwatched
/// time. `MPRemoteCommand.isEnabled` is the switch, and a disabled command is
/// not merely inert — the control disappears from the Now Playing UI.
///
/// Play and pause are deliberately left alone. They reach the `AVPlayer` like
/// any other pause, and the session reports them as §3.14.1 `pause` and
/// `resume` — see `VASTPlaybackController.observePlaybackStatus()`.
///
/// Nothing here is registered, because there is nothing to register: both
/// `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are process-wide
/// singletons. So this snapshots and restores instead, the way the playback
/// controller does with the host's player item.
@MainActor
final class VASTNowPlayingController {

    private let policy: VASTAdSession.NowPlayingPolicy

    /// Everything that would move the playhead or leave the creative.
    ///
    /// `changePlaybackRateCommand` belongs here for a less obvious reason than
    /// the rest: watched time is measured from the playhead, so a creative
    /// played at 2× is watched in half the time and every quartile still fires.
    private let locked: [MPRemoteCommand] = {
        let center = MPRemoteCommandCenter.shared()
        return [
            center.changePlaybackPositionCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.changePlaybackRateCommand,
        ]
    }()

    private var savedEnabled: [Bool] = []
    /// The host's Now Playing information. `nil` is a real value here — a host
    /// that published none must be given none back, not left with the ad's.
    private var savedInfo: [String: Any]?
    /// Whether there is anything to give back. `savedInfo` cannot answer this;
    /// `nil` is one of the states being remembered.
    private var didSnapshot = false

    init(policy: VASTAdSession.NowPlayingPolicy) {
        self.policy = policy
    }

    private var infoCenter: MPNowPlayingInfoCenter { .default() }

    // MARK: - Break lifetime

    func adBreakDidBegin() {
        guard policy != .untouched, !didSnapshot else { return }
        didSnapshot = true

        savedEnabled = locked.map(\.isEnabled)
        for command in locked { command.isEnabled = false }

        guard policy == .describesAd else { return }
        savedInfo = infoCenter.nowPlayingInfo
    }

    /// Describes the creative now on screen.
    ///
    /// Elapsed time and rate are published once rather than on every tick: the
    /// system extrapolates the playhead from the pair, so writing the dictionary
    /// five times a second would buy nothing and cost an IPC each time. What has
    /// to be republished is a *change* of rate, which is what `notePlayback`
    /// is for.
    func adDidStart(_ ad: VASTAd, duration: TimeInterval) {
        guard policy == .describesAd, didSnapshot else { return }

        var info: [String: Any] = [
            // `<AdTitle>` when the response carried one. The fallback is the
            // SDK's own word for it, localised — a lock screen reading
            // "Advertisement" in an Armenian app is the same mistake an English
            // skip control would be.
            MPMediaItemPropertyTitle: ad.title ?? VASTStrings.text("nowplaying.title"),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        // `<Advertiser>` (§3.9). Left out rather than guessed at when the
        // response does not say who the ad is for.
        if let advertiser = ad.advertiser {
            info[MPMediaItemPropertyArtist] = advertiser
        }
        infoCenter.nowPlayingInfo = info
    }

    /// The ad was paused or resumed. Publishes the new rate, and the playhead it
    /// stopped at, so the lock screen's own timer stops where the ad did.
    func notePlayback(isPlaying: Bool, elapsed: TimeInterval) {
        guard policy == .describesAd, didSnapshot,
              var info = infoCenter.nowPlayingInfo
        else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        infoCenter.nowPlayingInfo = info
    }

    /// Puts back what was found, command by command.
    ///
    /// The host's information comes back with the elapsed time it had when the
    /// break started, which is a moment out of date — the host's own next update
    /// corrects it, and inventing a position for someone else's content would be
    /// worse than being a moment stale.
    func adBreakDidEnd() {
        guard didSnapshot else { return }
        didSnapshot = false

        for (command, wasEnabled) in zip(locked, savedEnabled) {
            command.isEnabled = wasEnabled
        }
        savedEnabled = []

        guard policy == .describesAd else { return }
        infoCenter.nowPlayingInfo = savedInfo
        savedInfo = nil
    }
}
