//
//  VASTPictureInPictureCoordinator.swift
//  VASTSDK
//

import Foundation
import AVKit
import VASTCore

public extension VASTAdSession {

    /// Hands the session the host's Picture in Picture controller, so an ad break
    /// can apply `Configuration.pictureInPicture` to it.
    ///
    /// The SDK does not build the controller and could not: Picture in Picture is
    /// bound to an `AVPlayerLayer`, and the layer belongs to the host's player
    /// view — the same view the SDK deliberately does not own. What it needs is a
    /// handle, and the host is the only one holding one.
    ///
    /// The session becomes the controller's delegate and forwards every callback
    /// to whichever delegate was already set, so registering does not cost the
    /// host its own notifications. Set your delegate first; if you change it
    /// afterwards, the next ad break takes it over again and keeps forwarding.
    ///
    /// Outside an ad break nothing here starts or stops Picture in Picture. The
    /// window is the host's the rest of the time.
    func registerPictureInPicture(_ controller: AVPictureInPictureController) {
        pictureInPicture?.invalidate()
        pictureInPicture = VASTPictureInPictureCoordinator(controller: controller, session: self)
    }

    /// Gives the controller back: the host's delegate is restored and the session
    /// stops applying its policy.
    ///
    /// Worth calling when the player outlives the session. The controller holds
    /// its delegate weakly, so a session that is simply released leaves the
    /// controller with no delegate at all rather than with the host's.
    func unregisterPictureInPicture() {
        pictureInPicture?.invalidate()
        pictureInPicture = nil
    }
}

// MARK: - Policy

public extension VASTAdSession.PictureInPicturePolicy {

    /// What a break does when Picture in Picture turns on or off under it.
    ///
    /// Split out from the coordinator, and returned to it rather than acted on
    /// there, so the decision can be exercised without an
    /// `AVPictureInPictureController` — one cannot be built in a test process, so
    /// a policy folded into the delegate callbacks would be the one part of this
    /// that nothing ever checks.
    enum Reaction: Sendable, Equatable {
        case ignore
        /// Only the coordinator can do this one; it holds the controller.
        case stopPictureInPicture
        case pauseAd
        case resumeAd
        /// The ad is now in a window the ad surface cannot follow. Reported, not
        /// prevented: under `.allowed` the host said it wanted this.
        case reportUnreachableUI
    }

    func reaction(toPictureInPictureActive isActive: Bool) -> Reaction {
        switch self {
        case .suspended:
            isActive ? .stopPictureInPicture : .ignore
        case .pausesAd:
            isActive ? .pauseAd : .resumeAd
        case .allowed:
            isActive ? .reportUnreachableUI : .ignore
        }
    }
}

// MARK: - Coordinator

/// Applies the session's Picture in Picture policy to a controller the host owns,
/// for the length of an ad break and no longer.
///
/// The problem it exists for is not that Picture in Picture breaks playback — it
/// does not. `AVPictureInPictureController` is bound to a player *layer*, so it
/// survives the item swap that starts an ad and carries on showing whatever the
/// layer shows. The creative follows the content into the window without anyone
/// asking, and the ad surface does not: the skip control and the click layer are
/// views in the app, and the window draws a video layer and system transport
/// controls, nothing else.
///
/// The default is to let that happen — a viewer who opened the window asked for
/// it, and tapping the window brings them back to where the surface is. What the
/// policies exist for is the players that cannot accept it, and for saying so
/// when the skip control comes due with nobody in the app to see it.
/// `VASTSurfacePresence` cannot: the surface is still there, still full size,
/// just no longer where the ad is.
@MainActor
final class VASTPictureInPictureCoordinator: NSObject {

    private weak var session: VASTAdSession?
    private weak var controller: AVPictureInPictureController?
    /// The delegate the host had before the session took the seat. Every callback
    /// is passed on to it; taking over the delegate must not mean taking away the
    /// host's own Picture in Picture handling.
    private weak var hostDelegate: (any AVPictureInPictureControllerDelegate)?

    private var isBreakRunning = false
    /// Host settings changed for the break, kept so the break can put them back.
    /// `nil` means "not ours to restore" — restoring a value never saved would
    /// hand the host a default it did not choose.
    private var savedRequiresLinearPlayback: Bool?
    #if os(iOS)
    private var savedCanStartAutomatically: Bool?
    #endif

    init(controller: AVPictureInPictureController, session: VASTAdSession) {
        self.controller = controller
        self.session = session
        super.init()
        adoptDelegate(of: controller)
    }

    private var policy: VASTAdSession.PictureInPicturePolicy {
        session?.configuration.pictureInPicture ?? .suspended
    }

    private func adoptDelegate(of controller: AVPictureInPictureController) {
        guard controller.delegate !== self else { return }
        hostDelegate = controller.delegate
        controller.delegate = self
    }

    /// Restores everything this coordinator changed, including the delegate seat.
    func invalidate() {
        restoreHostSettings()
        if let controller, controller.delegate === self {
            controller.delegate = hostDelegate
        }
        hostDelegate = nil
        controller = nil
        isBreakRunning = false
    }

    // MARK: - Break lifetime

    func adBreakDidBegin() {
        guard let controller else { return }
        // A host that set its own delegate after registering would otherwise have
        // quietly cut the session out. Checked once per break rather than
        // observed: there is nothing to observe on a weak ObjC property.
        adoptDelegate(of: controller)
        isBreakRunning = true

        // Seeking has no meaning inside a linear creative — VAST defines no
        // attribute that would permit it, and the tracking engine treats a jump
        // as unwatched time — while the Picture in Picture window brings a
        // scrubber and a skip-forward button of its own. AVKit has a switch for
        // exactly this case, and it is the one part of the window the SDK can
        // reach.
        savedRequiresLinearPlayback = controller.requiresLinearPlayback
        controller.requiresLinearPlayback = true

        guard policy == .suspended else { return }

        #if os(iOS)
        // Backgrounding the app must not carry the ad into a window where the
        // skip control cannot follow it. iOS-only: the property does not exist on
        // tvOS or macOS, where nothing starts Picture in Picture by itself.
        savedCanStartAutomatically = controller.canStartPictureInPictureAutomaticallyFromInline
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        #endif

        // Already in the window when the break began — the viewer was watching
        // the content there. The ad is about to take that layer over.
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
    }

    /// A creative is now on screen. Re-asks the question, because a window that
    /// was already open raises no callback of its own.
    func adDidStart() {
        guard isBreakRunning, let controller else { return }
        apply(isActive: controller.isPictureInPictureActive)
    }

    func adBreakDidEnd() {
        isBreakRunning = false
        restoreHostSettings()
        // Deliberately does not put the window back. Re-entering Picture in
        // Picture here would open it while the viewer is looking at the app —
        // the break only ends once they are back — which is a window nobody
        // asked for. Restoring the automatic-entry setting is the honest half:
        // the next time they leave, it behaves as the host configured it.
    }

    private func restoreHostSettings() {
        guard let controller else { return }
        if let saved = savedRequiresLinearPlayback {
            controller.requiresLinearPlayback = saved
            savedRequiresLinearPlayback = nil
        }
        #if os(iOS)
        if let saved = savedCanStartAutomatically {
            controller.canStartPictureInPictureAutomaticallyFromInline = saved
            savedCanStartAutomatically = nil
        }
        #endif
    }

    /// Tells the session what happened and carries out the part it cannot.
    private func apply(isActive: Bool) {
        guard let session else { return }
        if session.notePictureInPicture(isActive: isActive) == .stopPictureInPicture {
            controller?.stopPictureInPicture()
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

// `@preconcurrency`: AVKit's delegate protocol carries no actor annotation, so a
// main-actor method cannot satisfy it under Swift 6 without one. The callbacks do
// arrive on the main thread — this states that rather than pretending otherwise
// with a hop that would report the change one runloop late.
extension VASTPictureInPictureCoordinator: @preconcurrency AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        hostDelegate?.pictureInPictureControllerWillStartPictureInPicture?(controller)
    }

    /// The host hears first, then the policy runs. The other order meant a
    /// `.suspended` stop was issued from inside this call, so the host saw
    /// `willStop` before the `didStart` it was still waiting for.
    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        hostDelegate?.pictureInPictureControllerDidStartPictureInPicture?(controller)
        apply(isActive: true)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        hostDelegate?.pictureInPictureController?(
            controller, failedToStartPictureInPictureWithError: error
        )
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        hostDelegate?.pictureInPictureControllerWillStopPictureInPicture?(controller)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        hostDelegate?.pictureInPictureControllerDidStopPictureInPicture?(controller)
        apply(isActive: false)
    }

    /// Forwarded, or answered. The method is optional, so a host that does not
    /// implement it would leave the completion handler uncalled — and an uncalled
    /// completion handler here leaves the window stuck mid-dismissal for good.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        // AVKit hands this block over as non-`Sendable` and takes it back as
        // `@Sendable` — the same closure, described two different ways by the
        // same framework. Both ends are the main thread; the box says so, rather
        // than letting an import artefact decide the shape of the forwarding.
        let handler = UncheckedSendableBox(completionHandler)
        let forwarded: Void? = hostDelegate?.pictureInPictureController?(
            controller,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: {
                handler.value($0)
            }
        )
        if forwarded == nil { completionHandler(true) }
    }
}

/// Carries a value across a `@Sendable` boundary the compiler cannot check and
/// this file does not actually cross: everything here runs on the main actor.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
