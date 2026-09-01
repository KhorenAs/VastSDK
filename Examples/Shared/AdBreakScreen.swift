//
//  AdBreakScreen.swift
//  VASTDemo
//

import Foundation
import AVFoundation
import AVKit
import Combine
import VASTCore
import VASTKit

/// Everything one player screen owns: the `AVPlayer`, the ad session, and the
/// content transport.
///
/// One owner on purpose. Previously the view held the player, and so did the
/// session, and so did the content model — three references created in the view's
/// `init`, which SwiftUI re-runs on every redraw. An `AVPlayer` that is genuinely
/// released stops making sound on its own, so the way to guarantee silence after
/// the screen goes away is for exactly one object to own it and for that object
/// to be the thing SwiftUI releases.
@MainActor
final class AdBreakScreen: ObservableObject {

    /// Live instances. After backing out of every player screen this must read
    /// zero; a number that stays up is a screen — and its player — still alive.
    ///
    /// Counted in `init`/`deinit`, deliberately. An earlier version decremented in
    /// `invalidate()`, which measured "teardown was called" rather than "the
    /// object went away" — so it would have read zero while leaking, which is
    /// worse than no diagnostic at all.
    ///
    /// `deinit` is nonisolated, so the counter cannot be actor-bound. A lock keeps
    /// it correct and a main-actor mirror keeps it observable.
    final class LiveCount: @unchecked Sendable, ObservableObject {

        static let shared = LiveCount()

        @Published private(set) var value = 0
        private let lock = NSLock()
        private var count = 0

        fileprivate func adjust(_ delta: Int) {
            lock.lock()
            count += delta
            let snapshot = count
            lock.unlock()
            // Published on the next turn: `AdBreakScreen` is built inside
            // `StateObject(wrappedValue:)`, which SwiftUI evaluates during a view
            // update, and publishing from there is undefined behaviour.
            Task { @MainActor in self.value = snapshot }
        }
    }

    let scenario: DemoScenario
    let player: AVPlayer
    let session: VASTAdSession
    let content: ContentPlayerModel
    /// The host's own system transport, so there is something for the SDK to
    /// borrow and give back.
    let nowPlaying: DemoNowPlaying

    /// The Picture in Picture controller, once the player view has handed over
    /// its layer. Owned here for the reason everything else is: one object per
    /// screen, so releasing the screen releases the lot.
    private(set) var pictureInPicture: AVPictureInPictureController?
    /// Whether the window can be opened right now — false until the layer is
    /// on screen with something playable in it, which is why the button is
    /// bound to this rather than to the controller merely existing.
    @Published private(set) var isPictureInPicturePossible = false
    /// Mirrored from the session so the demo's own button can read it without
    /// each host having to observe a second `ObservableObject`.
    @Published private(set) var isInPictureInPicture = false
    private var pictureInPictureObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []

    @Published private(set) var log: [String] = []
    @Published private(set) var isBusy = false
    private var didStartFirstBreak = false

    init(scenario: DemoScenario) {
        self.scenario = scenario
        let player = AVPlayer(url: DemoCatalog.contentStream)
        self.player = player
        // A scenario that hands the ad UI to the host hands it the §2.3 skip
        // obligation too, so the two settings travel together and no screen can
        // opt into half of it.
        self.session = VASTAdSession(
            player: player,
            configuration: VASTAdSession.Configuration(
                skipPresentation: scenario.hostDrawsUI ? .host : .sdk,
                // tvOS has no pointer, and a transparent layer takes no focus, so
                // `.surface` cannot work there — the SDK says so through the
                // delegate rather than drawing something inert. A real tvOS host
                // uses `.host` with a focusable control of its own; a demo with no
                // such control opts out knowingly instead of pretending.
                clickPresentation: Self.clickPresentation,
                // Chosen on the list screen: the policy is part of the session's
                // configuration, so it is fixed for the life of this screen.
                pictureInPicture: DemoSettings.shared.pictureInPicture
            )
        )
        self.session.isHiddenUi = scenario.hostDrawsUI
        self.content = ContentPlayerModel(player: player)
        self.nowPlaying = DemoNowPlaying(player: player, title: scenario.title)

        LiveCount.shared.adjust(1)
        configureAudioSession()

        nowPlaying.activate()

        // The default delegate. UIKit and AppKit replace it with the view
        // controller, which is the point of those demos; SwiftUI has nothing
        // else to be one, and a compliance warning nobody prints is a warning
        // nobody sees while testing.
        session.delegate = self

        // `dropFirst` because a `@Published` publisher delivers its current value
        // on subscribe, and "not in the window" is not an event.
        session.$isInPictureInPicture
            .dropFirst()
            .sink { [weak self] isActive in
                guard let self else { return }
                self.isInPictureInPicture = isActive
                self.note("picture in picture · \(isActive ? "entered" : "left")")
            }
            .store(in: &cancellables)
    }

    deinit {
        // The only honest place to count a release.
        LiveCount.shared.adjust(-1)
    }

    /// Called when the screen goes away. Explicit rather than left to `deinit`,
    /// which under strict concurrency cannot touch any of this.
    func invalidate() {
        cancellables.removeAll()
        pictureInPictureObservation?.invalidate()
        pictureInPictureObservation = nil
        session.unregisterPictureInPicture()
        pictureInPicture = nil
        session.stop()
        content.pause()
        content.invalidate()
        nowPlaying.invalidate()
        // Nothing should be left holding the player after this; releasing it is
        // what actually stops the sound.
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Picture in Picture

    /// Called by the player view once its `AVPlayerLayer` exists.
    ///
    /// The layer is what Picture in Picture is built from, and the host is the
    /// only one who has it — which is the whole reason the SDK is handed a
    /// controller rather than making one.
    ///
    /// Idempotent, because SwiftUI rebuilds the view: a second controller on the
    /// same layer would leave the session holding the one no longer driving the
    /// window.
    func adoptPlayerLayer(_ layer: AVPlayerLayer) {
        guard pictureInPicture?.playerLayer !== layer else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer)
        else {
            // Deferred for the same reason as the published state below.
            Task { @MainActor in self.note("picture in picture is not supported here") }
            return
        }

        #if os(iOS)
        // The half worth testing: leaving the app during a break is what opens
        // the window with nobody asking, and it is what `.suspended` has to
        // switch off for as long as the break runs.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif

        pictureInPicture = controller
        session.registerPictureInPicture(controller)

        // Published on the next turn, not here. SwiftUI calls this from
        // `makeUIView`, which runs in the middle of a view update, and
        // publishing from there is undefined behaviour — the same trap
        // `LiveCount.adjust` documents. It also does the button a favour: the
        // redraw it schedules is what puts the control on screen at all, since
        // `pictureInPicture` itself publishes nothing.
        let possible = controller.isPictureInPicturePossible
        Task { @MainActor in self.isPictureInPicturePossible = possible }

        // A button bound to `isPictureInPicturePossible` rather than to the
        // controller existing: the window cannot open until the layer is on
        // screen with something playable in it.
        pictureInPictureObservation = controller.observe(
            \.isPictureInPicturePossible, options: [.new]
        ) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in self?.isPictureInPicturePossible = possible }
        }
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            pictureInPicture.startPictureInPicture()
        }
    }

    /// Picture in Picture opens for nobody without these two: the `audio`
    /// background mode in the Info.plist, and a `.playback` session that has
    /// actually been activated. A demo that skipped this would look like the SDK
    /// was ignoring the window.
    private func configureAudioSession() {
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Called from `init`, which SwiftUI runs inside
            // `StateObject(wrappedValue:)` — a view update like any other.
            Task { @MainActor in self.note("audio session failed · \(error.localizedDescription)") }
        }
        #endif
    }

    /// Where a click can come from on this platform.
    static var clickPresentation: VASTAdSession.ClickPresentation {
        #if os(tvOS)
        .disabled
        #else
        .surface
        #endif
    }

    var isPlayingAd: Bool {
        switch session.state {
        case .playing, .paused: true
        case .idle, .loading, .finished: false
        }
    }

    // MARK: - Flow

    func start() async {
        content.play()
        guard !didStartFirstBreak else { return }
        didStartFirstBreak = true

        // `try?` here was the leak. SwiftUI cancels this task when the screen is
        // dismissed, `Task.sleep` throws in response — and `try?` swallowed it, so
        // execution carried straight on into the break. The screen was gone, but
        // the task went on loading and playing an ad, holding the screen (and its
        // player, and the audio) alive until the creative finished.
        do {
            // Let the content establish itself, so the hand-over and the return
            // are both visible.
            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        await runBreak()
    }

    func runBreak() async {
        guard !isBusy, !Task.isCancelled else { return }
        isBusy = true
        defer { isBusy = false }

        log.removeAll()
        note("load \(scenario.id)")
        do {
            switch scenario.source {
            case .tag(let url): try await session.load(tag: DemoCatalog.requestReady(url))
            case .xml(let xml): try await session.load(xml: xml)
            }
        } catch VASTAdSession.SessionError.stopped {
            // The screen was dismissed while the response was loading.
            return
        } catch let error as VASTError {
            note("failed · VAST \(error.rawValue) \(error)")
            return
        } catch {
            note("failed · \(error)")
            return
        }

        // Between the request going out and the response arriving, the screen may
        // have been dismissed. `await` on its own does not notice.
        guard !Task.isCancelled else { return }

        note("resolved \(session.adPosition.total) slot(s) to play")
        content.isSuspended = true
        // Two writers on one MPNowPlayingInfoCenter would fight: the host's next
        // update would overwrite the ad's title a moment after the SDK set it.
        nowPlaying.isSuspended = true
        let outcome = await session.play()
        nowPlaying.isSuspended = false
        content.isSuspended = false
        note("break finished · \(outcome)")
    }

    var hasPlayedOnce: Bool { didStartFirstBreak }

    func note(_ line: String) {
        log.append(line)
    }
}

// MARK: - Compliance warnings

/// Only the warnings. Everything else about a break is `@Published` state the
/// hosts already read; these two are reasons, which no amount of state carries.
extension AdBreakScreen: iVASTAdSessionDelegate {

    func session(_ session: VASTAdSession, skipControlUnavailableFor ad: VASTAd, reason: String) {
        note("⚠︎ skip control unavailable · \(reason)")
    }

    func session(_ session: VASTAdSession, clickThroughUnavailableFor ad: VASTAd, reason: String) {
        note("⚠︎ click path unavailable · \(reason)")
    }
}
