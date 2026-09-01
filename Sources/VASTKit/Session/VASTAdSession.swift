//
//  VASTAdSession.swift
//  VASTSDK
//

import Foundation
import AVFoundation
import Combine
import VASTCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Plays one VAST response on a host-supplied `AVPlayer` and reports tracking.
///
/// The session owns no UI. It publishes state (`ObservableObject`, for SwiftUI)
/// and forwards the same transitions to `iVASTAdSessionDelegate` (for UIKit and
/// AppKit hosts). Drawing the skip control is the host's job — see `canSkip`.
@MainActor
public final class VASTAdSession: ObservableObject {

    // MARK: - Published state (SwiftUI)

    @Published public internal(set) var state: State = .idle
    @Published public internal(set) var currentAd: VASTAd?
    /// Position within the pod, 1-based. `(1, 1)` for a single ad.
    @Published public internal(set) var adPosition: AdPosition = .single
    @Published public internal(set) var remainingTime: TimeInterval = 0
    /// `true` once `skipoffset` has elapsed on a skippable ad.
    @Published public internal(set) var canSkip = false
    /// Seconds until the skip control unlocks; `nil` when the ad is not skippable.
    @Published public internal(set) var timeUntilSkip: TimeInterval?

    /// Whether the player is currently in the Picture in Picture window.
    ///
    /// Only ever true when the host registered a controller — the SDK has no
    /// other way to know, and does not guess. See `registerPictureInPicture`.
    @Published public internal(set) var isInPictureInPicture = false

    /// Whether the host is willing to draw the whole ad UI itself when a
    /// response asks it to.
    ///
    /// `false`, the default, means the SDK draws its own UI whatever the response
    /// says. That is deliberate: `<Extensions>` is vendor territory, and a
    /// vendor key must not be able to take the §2.3 skip promise away from a host
    /// that never agreed to honour it.
    ///
    /// Set it to `true` and the SDK reads the `uiSettings` UI-hidden key from the
    /// response. When the key is there the SDK draws nothing at all — no badge,
    /// no countdown, no click layer and no skip control — and the entire ad UI
    /// becomes yours. Pair it with `skipPresentation = .host`, which is the
    /// statement that you accept that obligation; leaving it at `.sdk` is
    /// reported through the delegate, because the control the SDK promised is
    /// then on nobody's screen.
    ///
    /// `suppressesAdUI` is the answer for the ad currently playing.
    @Published public var isHiddenUi = false

    /// Whether a host's own Picture in Picture control should be offered right
    /// now.
    ///
    /// False while a break is running under `.suspended`, and true the rest of
    /// the time. Worth binding a control to, because AVKit gives no way to refuse
    /// a start: `canStartPictureInPictureAutomaticallyFromInline` covers only
    /// automatic entry, and the delegate's `willStart` cannot cancel. A button
    /// left enabled under `.suspended` therefore opens the window and has it
    /// closed again a moment later — correct, and visibly clumsy. Only the host
    /// can hide its own control, so this is the SDK answering rather than each
    /// host working it out.
    ///
    /// The other policies leave the window to the viewer, so it stays true.
    ///
    /// Derived from `state` rather than from the break's own internals, so that
    /// it changes when a published value does and a SwiftUI control bound to it
    /// actually redraws.
    public var permitsPictureInPicture: Bool {
        guard configuration.pictureInPicture == .suspended else { return true }
        return switch state {
        case .loading, .playing, .paused: false
        case .idle, .finished: true
        }
    }

    /// Whether the ad on screen right now must be drawn by the host: the host
    /// allowed it *and* this response asked for it.
    public var suppressesAdUI: Bool {
        guard isHiddenUi, let ad = currentAd else { return false }
        return ad.isUIHidden
    }

    public weak var delegate: (any iVASTAdSessionDelegate)?

    /// Third-party measurement, if anything is going to execute the ad's
    /// `<AdVerifications>`. Set it before `play()`.
    ///
    /// Held strongly, unlike `delegate`: a measurement integration is usually
    /// created for the session and holds the vendor session state, and a weak
    /// reference there fails by silently measuring nothing — the one failure a
    /// measurement layer must not have.
    ///
    /// Leaving this `nil` is not a gap: the SDK then reports
    /// `verificationNotExecuted` to every vendor that asked, which is the honest
    /// answer and the whole reason the field is optional.
    public var measurement: (any iVASTAdMeasurement)?

    let player: AVPlayer
    /// Read by the ad surface, which has to know who owns the skip control and
    /// whether the creative is clickable.
    public let configuration: any iConfiguration
    let transport: any iVASTBeaconTransport
    private let resolver: VASTTagResolver

    var scheduler: VASTPodScheduler?
    /// The engine for the ad on screen. Held here because `skip()` arrives from
    /// the host on a different call than the tick loop that owns playback.
    var activeEngine: VASTTrackingEngine?
    var activeClock: (any iVASTClock)?
    var skipRequested = false
    /// The break currently running, if any.
    ///
    /// Two concurrent breaks would share `activeEngine` and `activeClock` and
    /// corrupt each other: one loop reads the other's engine, exits immediately
    /// and leaves the published countdown frozen, while the other reports a
    /// completion it never earned. A host can call `load`/`play` whenever it
    /// likes, so the session — not the host — has to enforce one at a time.
    var activeBreak: Task<Outcome, Never>?
    /// The controller driving the current break, so it can be aborted from
    /// outside the loop that owns it.
    var activePlayback: VASTPlaybackController?
    /// The system's Now Playing controls, held for the length of a break. Built
    /// per break rather than per session: what it holds is a snapshot, and a
    /// snapshot outside a break is a snapshot of nothing.
    var nowPlaying: VASTNowPlayingController?
    /// The host's Picture in Picture controller, once it has been registered.
    /// Held for the life of the session rather than the break: the window can be
    /// opened before a break starts, and the policy has to be there when it is.
    var pictureInPicture: VASTPictureInPictureCoordinator?
    /// Bumped by `stop()`. Work that was already in flight compares the token it
    /// started with and discards its result if the session has moved on.
    ///
    /// Without this, `stop()` clearing the schedule was not enough: a `load`
    /// still resolving would come back afterwards, put the schedule back, and the
    /// `play` queued behind it would start a break on a screen that had already
    /// been dismissed — audible, and with nothing left to stop it.
    private var generation = 0

    /// The last tick seen, so a beacon can report where the playhead was — the
    /// ad server asked for `[ADPLAYHEAD]`, not for "somewhere in the ad".
    var lastTick: VASTTick?
    /// The creative being played, for `[ASSETURI]`.
    var currentMediaFile: VASTAd.MediaFile?
    /// `[TRANSACTIONID]` — one value for one break, so an ad server can tie a
    /// break's beacons together without guessing from timestamps. Regenerated per
    /// break rather than per session: two breaks on one screen are two
    /// transactions.
    var transactionID: String?
    let macros = VASTMacroExpander()
    /// Weak on purpose. The surface holds the session so it can read published
    /// state, and the container it was added to owns the surface — so a strong
    /// handle here closes a cycle that keeps the session, its `AVPlayer` and the
    /// decoded creative alive for the rest of the process. All this reference is
    /// for is being able to remove the view again.
    /// The surface pinned by `attach(to:)`, when the host took that route.
    /// Measurement needs a view to measure, and this is the only one the SDK is
    /// ever handed.
    weak var attachedSurface: VASTAdSurfaceView?

    /// What is known about the ad surface being on screen. Reported by the
    /// surface itself; see `VASTSurfacePresence` for what it can and cannot see.
    public private(set) var surfacePresence = VASTSurfacePresence()
    /// One complaint per ad: the control is re-measured on every layout pass, and
    /// a warning repeated forty times a second helps nobody.
    private var reportedSkipControlProblem = false
    /// The same, for the window. Entering and leaving it repeatedly during one ad
    /// is one mistake, not one per trip.
    private var reportedPictureInPictureProblem = false

    func noteSurface(size: CGSize) {
        surfacePresence.update(size: size)
    }

    /// Reports a vendor's resource as having failed to load.
    ///
    /// Only the measurement layer can know this — the SDK never fetches a
    /// verification resource — so `resourceLoadError` reaches the vendor through
    /// here or not at all. Firing it is additive: the SDK stayed silent about
    /// this ad precisely because measurement was configured.
    public func reportVerificationNotExecuted(
        _ verification: VASTAd.Verification,
        reason: VASTAd.Verification.NotExecutedReason = .resourceLoadError
    ) {
        guard let ad = currentAd else { return }
        send(verification.notExecutedTrackers.map {
            VASTBeacon(kind: .verificationNotExecuted(reason), url: $0, adID: ad.id)
        })
    }

    /// Each ad in a pod gets its own control, and its own chance to be wrong.
    func resetComplianceReports() {
        reportedSkipControlProblem = false
        reportedPictureInPictureProblem = false
    }

    /// Reported when the skip control is laid out, which is the only moment its
    /// real size exists. Judged here rather than at unlock time: the control is
    /// drawn after `canSkip` flips, so asking then would read a size that has not
    /// happened yet.
    func noteSkipControl(size: CGSize) {
        surfacePresence.update(skipControlSize: size)
        guard configuration.skipPresentation == .sdk,
              let ad = currentAd, ad.isSkippable,
              !reportedSkipControlProblem,
              let diagnosis = surfacePresence.skipControlDiagnosis
        else { return }
        reportedSkipControlProblem = true
        VASTLog.compliance.warning("skip control unavailable: \(diagnosis, privacy: .public)")
        delegate?.session(self, skipControlUnavailableFor: ad, reason: diagnosis)
    }

    /// §3.10.1 makes ClickThrough support Required, and the surface is how the
    /// SDK provides it — except where a transparent sheet cannot be reached at
    /// all. Saying so is the difference between a host choosing `.host` and a
    /// host shipping an ad nobody can click.
    func verifyClickPath(for ad: VASTAd) {
        #if os(tvOS)
        guard configuration.clickPresentation == .surface,
              ad.linear.clickThrough != nil
        else { return }
        let reason = """
        clickPresentation is .surface, but tvOS has no pointer and a transparent \
        layer cannot take focus, so this ad has no click path. Set \
        clickPresentation to .host and call click() from a focusable control of \
        your own, or to .disabled to opt out knowingly.
        """
        VASTLog.compliance.warning("click path unavailable: \(reason, privacy: .public)")
        delegate?.session(self, clickThroughUnavailableFor: ad, reason: reason)
        #endif
    }

    /// The ad UI is being suppressed at the response's request, but the host
    /// never took the skip control over. Reported rather than refused: unlike
    /// `skipPresentation = .unsupported`, the host did opt in here — it just
    /// opted in to half of what that means.
    func verifyHostDrawnUI(for ad: VASTAd) {
        guard suppressesAdUI, ad.isSkippable, configuration.skipPresentation == .sdk else { return }
        let reason = """
        the response asked for host-drawn UI and isHiddenUi permits it, so the SDK \
        is drawing nothing — but skipPresentation is still .sdk, which promised \
        this skippable ad a control. Set skipPresentation to .host and draw one, \
        or leave isHiddenUi false for this break.
        """
        VASTLog.compliance.warning("skip control unavailable: \(reason, privacy: .public)")
        delegate?.session(self, skipControlUnavailableFor: ad, reason: reason)
    }

    /// Checks the one compliance promise the SDK cannot verify on its own, at the
    /// moment it actually matters: the control is due, so it had better be
    /// somewhere a viewer can reach.
    func verifySkipSurface(for ad: VASTAd) {
        // First, and before every guard below: a surface can be present, sized
        // and pinned by `attach(to:)` — passing all of them — and still not be
        // where the ad is.
        reportPictureInPictureUnreachableUI()

        guard configuration.skipPresentation == .sdk, ad.isSkippable else { return }
        // Already reported at the start of the ad, and no control was drawn to
        // measure — complaining again when the offset elapses says nothing new.
        guard !suppressesAdUI else { return }
        // `attach(to:)` means the SDK owns the surface and pinned it itself.
        guard attachedSurface == nil else { return }
        guard let diagnosis = surfacePresence.diagnosis else { return }
        // Reported, not fatal. This is a heuristic about someone else's layout,
        // and a heuristic that is wrong must not take the host's app down with
        // it — which is exactly what an assertion here did the first time the
        // probe misread a surface it had in fact been given.
        VASTLog.compliance.warning("skip control unavailable: \(diagnosis, privacy: .public)")
        delegate?.session(self, skipControlUnavailableFor: ad, reason: diagnosis)
    }

    /// The window opened or closed. Publishes it, tells the delegate, and decides
    /// what the running break does about it.
    ///
    /// - Returns: the part of the answer only the coordinator can carry out, since
    ///   the controller is not the session's to hold.
    @discardableResult
    func notePictureInPicture(isActive: Bool) -> PictureInPicturePolicy.Reaction {
        if isInPictureInPicture != isActive {
            isInPictureInPicture = isActive
            delegate?.session(self, pictureInPictureDidChange: isActive)
        }

        // Outside a break there is no ad to protect and no policy to apply: the
        // window is the host's own, and the SDK has no business closing it.
        guard currentAd != nil, activePlayback != nil else { return .ignore }

        let reaction = configuration.pictureInPicture.reaction(toPictureInPictureActive: isActive)
        switch reaction {
        case .pauseAd:
            pause()
        case .resumeAd:
            resume()
        case .reportUnreachableUI:
            reportPictureInPictureUnreachableUI()
        case .stopPictureInPicture, .ignore:
            break
        }
        return reaction
    }

    /// What `.allowed` costs, said out loud — and only when it costs anything.
    ///
    /// Reported at the moment the skip control comes due with the viewer out in
    /// the window, which is the only moment §2.3 promises something they cannot
    /// see. Not when the window opens: before `skipoffset` elapses no control is
    /// owed, and warning then would put a line in the log for every ad anyone
    /// ever watched in Picture in Picture.
    ///
    /// The click path is deliberately not reported. Unlike tvOS, where a
    /// transparent layer can never take focus, tapping the window returns to the
    /// app and the click layer is where it always was — one tap further, not
    /// unreachable.
    private func reportPictureInPictureUnreachableUI() {
        guard isInPictureInPicture, canSkip, !reportedPictureInPictureProblem,
              let ad = currentAd, ad.isSkippable,
              configuration.skipPresentation == .sdk, !suppressesAdUI
        else { return }
        reportedPictureInPictureProblem = true

        let reason = """
        the skip control came due while the ad was playing in the Picture in \
        Picture window, which draws the player layer and nothing else — the \
        viewer has to come back to the app to reach it. Set pictureInPicture to \
        .pausesAd or .suspended if that is not acceptable for your inventory.
        """
        VASTLog.compliance.warning("skip control not on screen: \(reason, privacy: .public)")
        delegate?.session(self, skipControlUnavailableFor: ad, reason: reason)
    }

    public init(player: AVPlayer, configuration: any iConfiguration = Configuration()) {
        self.player = player
        self.configuration = configuration
        self.transport = configuration.transport ?? VASTURLSessionTransport()
        self.resolver = VASTTagResolver(
            loader: configuration.loader ?? VASTURLSessionLoader(),
            maxDepth: configuration.maxWrapperDepth,
            timeout: configuration.wrapperTimeout
        )
    }

    // MARK: - Loading

    /// Requests a tag from an ad server and follows its Wrapper chain.
    ///
    /// Preferred over `load(xml:)` whenever the response comes from a URL: a
    /// `VASTAdTagURI` is often relative, and only the fetch location can resolve it.
    ///
    /// - Throws: `VASTError` describing why no ad could be produced. Every
    ///   `<Error>` URI collected on the way down has already been fired, as
    ///   §2.3.5.1 requires, before this throws.
    public func load(tag url: URL) async throws {
        let resolver = resolver
        try await load { try await resolver.resolve(tag: url) }
    }

    /// Loads a response already in hand. `baseURL` should be supplied when known,
    /// so that a relative `VASTAdTagURI` inside it can still be followed.
    public func load(xml: String, baseURL: URL? = nil) async throws {
        let resolver = resolver
        try await load { try await resolver.resolve(xml: xml, baseURL: baseURL) }
    }

    /// Runs `work`, giving up after `configuration.resolutionTimeout`.
    ///
    /// The budget is the whole response, not one hop. `wrapperTimeout` already
    /// bounds a single fetch, and five of those in series is half a minute — long
    /// past the point where a viewer stops believing an ad is coming.
    ///
    /// The error carries no `<Error>` beacons, unlike a timeout the resolver
    /// raises itself: only the chain knows which URIs are owed, and cutting it
    /// off from outside is exactly the case where the chain cannot say.
    private func withResolutionBudget<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let budget = configuration.resolutionTimeout
        guard budget > 0 else { return try await work() }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                throw VASTError.wrapperTimeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw VASTError.undefined }
            return first
        }
    }

    private func load(
        _ resolve: @escaping @Sendable () async throws -> VASTTagResolver.Resolution
    ) async throws {
        // Loading a new response mid-break abandons the old one rather than
        // running both; a "replay" button is otherwise a race by construction.
        await cancelActiveBreak()
        let token = generation
        state = .loading
        do {
            let resolution = try await withResolutionBudget(resolve)
            guard token == generation else { throw SessionError.stopped }
            guard !resolution.ads.isEmpty else { throw VASTError.noVASTResponseAfterWrappers }
            let scheduler = VASTPodScheduler(ads: resolution.ads)
            self.scheduler = scheduler
            adPosition = AdPosition(index: 0, total: scheduler.totalCount)
            state = .idle
        } catch let failure as VASTTagResolver.Failure {
            // The wrappers traversed are owed an error request even though the
            // caller is about to see a thrown error — but it is not awaited.
            // Awaiting it left `load` sitting in `.loading` until somebody else's
            // tracking host answered, which on a no-fill response meant the UI
            // never came back at all.
            send(failure.beacons)
            state = .finished(.failed(failure.error))
            throw failure.error
        } catch let stopped as SessionError {
            // Nothing to report: the host asked for this by stopping.
            throw stopped
        } catch let error as VASTError {
            // The same reason the caller is about to see. Falling through to
            // `.undefined` left `state` naming one failure and the thrown error
            // naming another — a host reading both got two different stories.
            state = .finished(.failed(error))
            throw error
        } catch {
            state = .finished(.failed(.undefined))
            throw error
        }
    }

    // MARK: - Ad surface

    /// Adds the SDK's ad UI to a container the host already owns.
    ///
    /// For UIKit and AppKit hosts. SwiftUI hosts compose `VASTAdSurface` in
    /// their own `ZStack` instead — same behaviour, idiomatic placement.
    /// - Note: the surface is added last and kept front-most, which is the one
    ///   thing the SwiftUI path cannot do — there, ordering is the host's.
    /// - Returns: the surface, because that is where the styling hooks live.
    ///   Without it a UIKit host could not reach `skipButtonBuilder` and friends
    ///   at all, and had to build the surface by hand — losing the front-most
    ///   pinning this method exists to provide.
    @discardableResult
    public func attach(to container: PlatformView) -> VASTAdSurfaceView {
        detach()
        let surface = VASTAdSurfaceView(session: self)
        surface.translatesAutoresizingMaskIntoConstraints = false

        // Added front-most in one step. Adding and then re-adding to reorder
        // re-parents the view on AppKit, which drops the constraints pinning it
        // and leaves the surface unsized — with no room for the control it is
        // supposed to guarantee.
        #if os(macOS)
        container.addSubview(surface, positioned: .above, relativeTo: nil)
        #else
        container.addSubview(surface)
        container.bringSubviewToFront(surface)
        #endif

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        attachedSurface = surface
        return surface
    }

    public func detach() {
        attachedSurface?.removeFromSuperview()
        attachedSurface = nil
    }

    /// Records a click on the creative.
    ///
    /// Fires every `<ClickTracking>` URI and returns the `<ClickThrough>`
    /// destination. Opening it is the host's decision: only the host knows
    /// whether that means a browser, an in-app sheet, or nothing at all on a TV.
    @discardableResult
    public func click() -> URL? {
        guard let ad = currentAd else { return nil }
        let beacons = ad.linear.clickTracking.map {
            VASTBeacon(kind: .clickTracking, url: $0, adID: ad.id)
        }
        send(beacons)
        return ad.linear.clickThrough
    }

    /// Reports an interaction that opens nothing — `<CustomClick>` (§3.10.3).
    ///
    /// Separate from `click()` on purpose. A click-through takes the viewer
    /// somewhere and its trackers say so; a custom click is the host saying "the
    /// viewer did something with the ad" without any destination. Real tags carry
    /// both, and firing one for the other misreports both.
    public func reportCustomClick() {
        guard var engine = activeEngine else { return }
        let beacons = engine.reportCustomClick()
        activeEngine = engine
        send(beacons)
    }

    /// Ends the running break and waits for it to actually be over.
    ///
    /// Aborting the playback controller is the part that matters: cancelling the
    /// task and stopping the clock still left a `begin` in flight, which would
    /// come back, swap in its creative and start playing on top of whatever
    /// replaced it.
    func cancelActiveBreak() async {
        guard let running = activeBreak else { return }
        activeBreak = nil
        activePlayback?.abort()
        activeClock?.stop()
        activeEngine = nil
        running.cancel()
        _ = await running.value
    }

    // MARK: - Playback control

    /// - Throws: `SkipError` when the current ad is not skippable, or when
    ///   `skipoffset` has not elapsed yet. Never silently ignores the request —
    ///   playing a skippable ad without honouring its skip control violates
    ///   VAST §2.3.
    public func skip() throws {
        guard let ad = currentAd else { throw SkipError.noActiveAd }
        guard ad.isSkippable else { throw SkipError.notSkippable }
        guard canSkip else { throw SkipError.notYetAvailable(after: timeUntilSkip ?? 0) }

        skipRequested = true
        if var engine = activeEngine {
            let beacons = engine.userDidSkip()
            activeEngine = engine
            send(beacons)
        }
        // Ending the tick stream lets the pod loop advance to the next ad.
        activeClock?.stop()
    }

    /// Pauses the ad on screen and reports it (§3.14.1 player operation metrics).
    ///
    /// Pause has to come through here rather than through the `AVPlayer`. The
    /// session re-issues playback on every tick so that an ad survives the system
    /// stopping it — iOS leaves `rate` at 0 after backgrounding and never resumes
    /// — and it cannot tell that apart from a host pausing behind its back, so a
    /// pause made on the player is undone within one tick and reported to nobody.
    ///
    /// Does nothing unless an ad is playing.
    public func pause() {
        guard state == .playing, let playback = activePlayback else { return }
        playback.pauseByUser()
        report(.pause)
        state = .paused
        // The lock screen's own clock runs on the rate it was last given, so a
        // pause it is not told about goes on counting.
        nowPlaying?.notePlayback(isPlaying: false, elapsed: lastTick?.adTime ?? 0)
    }

    /// Playback stopped or started without the session asking.
    ///
    /// The player is the host's, and the ad on it can be stopped by things the
    /// SDK does not own: the Picture in Picture window's own pause button, or a
    /// host reaching for `AVPlayer` directly. Both used to be invisible — the
    /// `pause` and `resume` §3.14.1 asks for went unsent, `state` went on
    /// claiming the ad was playing, and any measurement layer, which reads the
    /// beacons, was told the same thing.
    ///
    /// Routed through `pause()` and `resume()` rather than reported separately,
    /// so a stop the viewer made and a stop the host made produce the same
    /// beacons in the same order. Both guard on the state they need, which is
    /// what makes a spurious transition a no-op rather than a stray event.
    func noteExternalPlayback(isPlaying: Bool) {
        guard let playback = activePlayback else { return }

        guard !isPlaying else {
            resume()
            return
        }

        // The creative running out stops the player like anything else does.
        // Reporting `pause` after `complete` is a sequence no ad server should
        // ever be sent, so the end of the ad is not a pause.
        guard let engine = activeEngine, !engine.isFinished else { return }
        guard remainingTime > Self.endOfCreativeMargin else { return }

        // Leaving the app stops decoding too, and that is the system, not the
        // viewer — it lifts on its own and `resumeIfNeeded()` restarts it. The
        // exception is the window: playback carries on in it while the app is
        // away, so a stop there can only be the viewer's own control.
        guard !playback.isSuspendedBySystem || adMayPlayInPictureInPicture else { return }
        pause()
    }

    /// Whether the ad is in the Picture in Picture window *and* meant to be
    /// playing there. Under `.suspended` it is neither, and the pause seen while
    /// the window closes is the closing, not a viewer.
    private var adMayPlayInPictureInPicture: Bool {
        isInPictureInPicture && configuration.pictureInPicture != .suspended
    }

    /// How close to the end of a creative a stop stops being a pause.
    ///
    /// Wider than the engine's own completion margin and than one clock tick,
    /// because this has to hold whichever of the two arrives first — the item's
    /// end notification or the player's rate reaching zero.
    static let endOfCreativeMargin: TimeInterval = 0.5

    /// Resumes an ad paused by `pause()`, and reports that too.
    ///
    /// Does nothing unless the session is paused; in particular it will not
    /// override a pause the *system* imposed, which lifts on its own.
    public func resume() {
        guard state == .paused, let playback = activePlayback else { return }
        playback.resumeByUser()
        report(.resume)
        state = .playing
        nowPlaying?.notePlayback(isPlaying: true, elapsed: lastTick?.adTime ?? 0)
    }

    /// Reports an event the SDK cannot observe for itself — mute, fullscreen and
    /// the rest of §3.14.1's player operation metrics.
    ///
    /// Quartiles, `start` and `complete` are derived from observed playback and
    /// are refused here, so a host cannot fabricate a billable event. Reporting
    /// an event no `<Tracking>` element asked for is free and does nothing.
    public func report(_ event: VASTAd.TrackingEvent) {
        guard var engine = activeEngine else { return }
        let beacons = engine.report(event)
        activeEngine = engine
        send(beacons)
    }

    /// Abandons the break and hands the player back to the host.
    ///
    /// This is what a screen calls on its way out, so it also takes the ad UI
    /// down: leaving the surface behind leaves a view observing a session nobody
    /// is driving any more.
    public func stop() {
        // Invalidate first: a `load` or `play` already in flight has to be able
        // to tell that it is no longer wanted.
        generation += 1
        // Then order matters: abort so nothing in flight can start playing
        // again, and pause before the break's own teardown gets a chance to
        // restore the host's item and resume it.
        activePlayback?.abort()
        activeBreak?.cancel()
        // Cleared, not just cancelled. A cancelled task the session still holds
        // is still a task the session holds.
        activeBreak = nil
        activePlayback = nil
        activeClock?.stop()
        activeClock = nil
        activeEngine = nil
        scheduler = nil
        player.pause()
        detach()
        state = .idle
    }
}
