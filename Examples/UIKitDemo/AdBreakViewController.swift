//
//  AdBreakViewController.swift
//  UIKitDemo
//

#if canImport(UIKit) && !os(watchOS)

import UIKit
import Combine
import AVFoundation
import VASTCore
import VASTKit

/// UIKit host, laid out to match the SwiftUI demo's player screen section for
/// section: header, 16:9 player with the ad surface over it, the content
/// transport (replaced by a notice while an ad owns the player), the break
/// action with a state label, and the event log.
///
/// The behaviour is not written twice — `AdBreakScreen` is the same model the
/// SwiftUI screen drives, so only the pixels are. What differs is how state
/// arrives: Combine subscriptions and `iVASTAdSessionDelegate` here, `@Published`
/// and `ObservedObject` there.
///
/// Playback goes into a bare `AVPlayerLayer` (`PlayerHostView`) rather than
/// `AVPlayerViewController`: see `PlayerLayerView.swift` — the system controls
/// bring a scrubber, and VAST has no concept of seeking inside a creative.
final class AdBreakViewController: UIViewController {

    private let screen: AdBreakScreen
    private let playerView = PlayerHostView()
    /// Handed back by `attach(to:)`, which is also what keeps it front-most.
    private var adSurface: VASTAdSurfaceView?

    private var cancellables: Set<AnyCancellable> = []
    private var breakTask: Task<Void, Never>?

    // Header
    private let titleLabel = UILabel()
    private let sourceLabel = UILabel()

    // Transport, and the notice that stands in for it during a break
    private let transport = UIStackView()
    private let adNotice = UILabel()
    /// tvOS has no pointer to drag with and no `UISlider` at all, so it gets a
    /// read-only progress bar and leans on the remote's transport buttons — the
    /// same split the SwiftUI demo makes.
    #if os(tvOS)
    private let progress = UIProgressView(progressViewStyle: .default)
    #else
    private let scrubber = UISlider()
    #endif
    private let playPause = UIButton(type: .system)
    private let timecode = UILabel()
    private let buffering = UIActivityIndicatorView(style: .medium)
    #if !os(tvOS)
    private let back10 = UIButton(type: .system)
    private let forward10 = UIButton(type: .system)
    #endif

    // Actions and log
    private let breakButton = UIButton(type: .system)
    /// Opens the window by hand. The other way in — leaving the app mid-ad —
    /// needs no button, and is the case the policy exists for.
    private let pictureInPictureButton = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let logView = UITextView()

    /// The screen's own skip control, for the scenario whose response asks the
    /// player to draw nothing. The same pill the SDK is handed, drawn by the host
    /// instead — which is what makes the two paths comparable at a glance.
    private lazy var hostSkip: SkipPill = {
        let pill = SkipPill()
        pill.takesFocus = true
        pill.addTarget(self, action: #selector(skipTapped), for: .primaryActionTriggered)
        pill.isHidden = true
        return pill
    }()

    init(scenario: DemoScenario) {
        self.screen = AdBreakScreen(scenario: scenario)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = screen.scenario.title
        #if os(iOS)
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        #endif

        buildLayout()
        screen.session.delegate = self
        observe()
        render()

        // Held so it can be cancelled on the way out. SwiftUI's `.task` does that
        // for free; here a break left running would keep the screen and its player
        // alive — audible, with nothing on screen left to stop it.
        breakTask = Task { [screen] in await screen.start() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || isBeingDismissed else { return }
        breakTask?.cancel()
        screen.invalidate()
    }

    // MARK: - Layout

    /// Smaller on tvOS, where the player needs every point it can get.
    private static var logHeight: CGFloat {
        #if os(tvOS)
        100
        #else
        160
        #endif
    }

    private func buildLayout() {
        titleLabel.text = screen.scenario.title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0

        sourceLabel.text = sourceDescription
        sourceLabel.font = .preferredFont(forTextStyle: .caption2)
        sourceLabel.textColor = .secondaryLabel
        sourceLabel.lineBreakMode = .byTruncatingMiddle

        let header = UIStackView(arrangedSubviews: [titleLabel, sourceLabel])
        header.axis = .vertical
        header.spacing = 2
        header.alignment = .leading

        playerView.attach(player: screen.player, gravity: .resizeAspect)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        // The layer is what Picture in Picture is built from, and this view is
        // the only thing that has one.
        screen.adoptPlayerLayer(playerView.playerLayer)
        // The SDK owns the behaviour §2.3 and §3.10.1 require; the look is ours.
        let surface = screen.session.attach(to: playerView)
        surface.skipButtonBuilder = { remaining in
            let pill = SkipPill()
            pill.secondsUntilUnlock = remaining
            return pill
        }
        surface.clickThroughHandler = { [weak self] url in
            self?.screen.note(ClickThrough.open(url))
        }
        adSurface = surface
        playerView.addSubview(hostSkip)
        playerView.bringSubviewToFront(hostSkip)
        hostSkip.translatesAutoresizingMaskIntoConstraints = false

        buildTransport()

        let divider = UIView()
        divider.backgroundColor = .separator

        breakButton.addTarget(self, action: #selector(breakTapped), for: .primaryActionTriggered)
        pictureInPictureButton.addTarget(
            self, action: #selector(pictureInPictureTapped), for: .primaryActionTriggered
        )
        stateLabel.font = .preferredFont(forTextStyle: .caption1)
        stateLabel.textColor = .secondaryLabel
        let spacer = UIView()
        let actions = UIStackView(
            arrangedSubviews: [breakButton, pictureInPictureButton, spacer, stateLabel]
        )
        actions.alignment = .center
        actions.spacing = 16

        #if os(iOS)
        logView.isEditable = false
        #endif
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .clear
        logView.textColor = .secondaryLabel

        let column = UIStackView(
            arrangedSubviews: [header, playerView, transport, adNotice, divider, actions, logView]
        )
        column.axis = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        column.setCustomSpacing(8, after: header)
        column.setCustomSpacing(8, after: transport)
        column.setCustomSpacing(8, after: adNotice)
        column.setCustomSpacing(8, after: divider)
        column.setCustomSpacing(4, after: actions)

        // All the slack goes to the log. With `.fill` distribution every item
        // hugs at the same default priority, so on a large screen UIKit split the
        // spare height between the header and the action row — leaving the button
        // floating in the middle of a blank band. Only the log should grow.
        for row in [header, transport, adNotice, actions] {
            row.setContentHuggingPriority(.required, for: .vertical)
        }
        logView.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)

        view.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            hostSkip.trailingAnchor.constraint(equalTo: playerView.trailingAnchor, constant: -16),
            hostSkip.bottomAnchor.constraint(equalTo: playerView.bottomAnchor, constant: -16),

            divider.heightAnchor.constraint(equalToConstant: 1),
            adNotice.heightAnchor.constraint(equalToConstant: 62),
            logView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.logHeight),
        ])

        // 16:9 wanted 1012pt of a 1080pt screen on tvOS, which the rest of the
        // column cannot spare. Below `required` the ratio gives way instead of
        // fighting the column's own height, and holds exactly where it fits.
        let aspect = playerView.heightAnchor.constraint(
            equalTo: playerView.widthAnchor, multiplier: 9.0 / 16.0
        )
        aspect.priority = .defaultHigh
        aspect.isActive = true
    }

    /// The content transport, and the notice that replaces it. Hidden rather than
    /// disabled during a break: a scrubber must not exist while a linear creative
    /// is on screen, and hiding says so more clearly than greying out.
    private func buildTransport() {
        adNotice.text = "Content controls are unavailable during an ad"
        adNotice.font = .preferredFont(forTextStyle: .caption2)
        adNotice.textColor = .secondaryLabel
        adNotice.textAlignment = .center

        #if !os(tvOS)
        scrubber.minimumValue = 0
        scrubber.maximumValue = 1
        scrubber.addTarget(self, action: #selector(scrubbing), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside])
        #endif

        playPause.addTarget(self, action: #selector(togglePlayPause), for: .primaryActionTriggered)
        timecode.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timecode.textColor = .secondaryLabel

        let buttons = UIStackView()
        buttons.spacing = 20
        buttons.alignment = .center
        #if !os(tvOS)
        back10.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        back10.addTarget(self, action: #selector(stepBack), for: .primaryActionTriggered)
        forward10.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        forward10.addTarget(self, action: #selector(stepForward), for: .primaryActionTriggered)
        buttons.addArrangedSubview(back10)
        #endif
        buttons.addArrangedSubview(playPause)
        #if !os(tvOS)
        buttons.addArrangedSubview(forward10)
        #endif
        buttons.addArrangedSubview(UIView())
        buttons.addArrangedSubview(buffering)
        buttons.addArrangedSubview(timecode)

        transport.axis = .vertical
        transport.spacing = 8
        #if os(tvOS)
        transport.addArrangedSubview(progress)
        #else
        transport.addArrangedSubview(scrubber)
        #endif
        transport.addArrangedSubview(buttons)
    }

    private var sourceDescription: String {
        switch screen.scenario.source {
        case .tag(let url): "tag · \(url.host ?? url.absoluteString)"
        case .xml: "local response"
        }
    }

    // MARK: - State

    /// Three publishers rather than one: the screen owns the log, the session the
    /// ad state, the content model the transport. `render()` is cheap and
    /// idempotent, so all three land in the same place.
    private func observe() {
        let publishers = [
            screen.objectWillChange.eraseToAnyPublisher(),
            screen.session.objectWillChange.eraseToAnyPublisher(),
            screen.content.objectWillChange.eraseToAnyPublisher(),
        ]
        for publisher in publishers {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.render() }
                .store(in: &cancellables)
        }
    }

    private func render() {
        let isPlayingAd = screen.isPlayingAd
        // Asked of the session rather than derived from `isPlayingAd`: it also
        // covers the moment a response is still resolving, and it is the same
        // answer `registerPlaybackControls` applies for an AVKit host.
        transport.isHidden = !screen.session.permitsPlaybackControls
        adNotice.isHidden = !isPlayingAd

        #if os(tvOS)
        progress.progress = Float(screen.content.progress)
        #else
        scrubber.value = Float(screen.content.progress)
        #endif
        playPause.setImage(
            UIImage(systemName: screen.content.isPlaying ? "pause.fill" : "play.fill"),
            for: .normal
        )
        timecode.text = ContentPlayerModel.timecode(screen.content.currentTime)
            + " / " + ContentPlayerModel.timecode(screen.content.duration)
        if screen.content.isBuffering {
            buffering.startAnimating()
        } else {
            buffering.stopAnimating()
        }

        renderBreakButton()
        renderPictureInPictureButton()
        stateLabel.text = stateDescription

        let text = screen.log.joined(separator: "\n")
        if logView.text != text {
            logView.text = text
            // Follow the tail, the way the SwiftUI log scrolls itself.
            logView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
        }

        // Only the SDK's surface is suppressed for that scenario; this control is
        // the host's answer to it.
        if screen.scenario.hostDrawsUI {
            hostSkip.secondsUntilUnlock = nil
            hostSkip.isHidden = !(isPlayingAd && screen.session.canSkip)
        }
    }

    /// Hidden where the window cannot exist at all, disabled where it exists but
    /// cannot open yet — the layer has to be on screen with something playable in
    /// it before `startPictureInPicture` does anything.
    private func renderPictureInPictureButton() {
        // Hidden outright while the session says the window is not on offer:
        // under `.suspended` a press opens it and has it shut again a moment
        // later — the right outcome, reached the ugly way.
        pictureInPictureButton.isHidden =
            screen.pictureInPicture == nil || !screen.session.permitsPictureInPicture
        pictureInPictureButton.isEnabled = screen.isPictureInPicturePossible
        pictureInPictureButton.setTitle(
            screen.isInPictureInPicture ? "Leave PiP" : "PiP", for: .normal
        )
    }

    /// One button, four meanings — a label reading "Replay" before anything has
    /// played, or tappable while a response is still loading, describes a state
    /// the session is not in.
    private func renderBreakButton() {
        switch screen.session.state {
        case .loading:
            breakButton.setTitle("Loading…", for: .normal)
            breakButton.isEnabled = false
            breakButton.tintColor = nil

        case .playing, .paused:
            breakButton.setTitle("Stop ad break", for: .normal)
            breakButton.isEnabled = true
            breakButton.tintColor = .systemRed

        case .idle, .finished:
            breakButton.setTitle(screen.hasPlayedOnce ? "Replay ad break" : "Play ad break", for: .normal)
            breakButton.isEnabled = !screen.isBusy
            breakButton.tintColor = nil
        }
    }

    private var stateDescription: String {
        switch screen.session.state {
        case .idle: "idle"
        case .loading: "loading…"
        case .playing: "playing ad"
        case .paused: "paused"
        case .finished(let outcome): "finished · \(outcome)"
        }
    }

    // MARK: - Actions

    @objc private func breakTapped() {
        switch screen.session.state {
        case .playing, .paused:
            // Deliberately an action rather than a gap: this is the teardown path
            // that used to leave an abandoned ad still audible.
            screen.session.stop()
        case .idle, .finished:
            Task { [screen] in await screen.runBreak() }
        case .loading:
            break
        }
    }

    @objc private func pictureInPictureTapped() { screen.togglePictureInPicture() }

    @objc private func skipTapped() {
        do { try screen.session.skip() } catch { screen.note("skip refused · \(error)") }
    }

    @objc private func togglePlayPause() { screen.content.togglePlayPause() }
    @objc private func stepBack() { screen.content.step(by: -10) }
    @objc private func stepForward() { screen.content.step(by: 10) }
    #if !os(tvOS)
    @objc private func scrubbing() { screen.content.scrub(toProgress: Double(scrubber.value)) }
    @objc private func scrubEnded() { screen.content.commitScrub() }
    #endif
}

// MARK: - Session delegate

/// The log lines the SwiftUI screen reads out of `@Published` state, this screen
/// gets from the delegate — the same events, arriving the other way round.
extension AdBreakViewController: iVASTAdSessionDelegate {

    func session(_ session: VASTAdSession, didStart ad: VASTAd, at position: VASTAdSession.AdPosition) {
        screen.note("start \(ad.id)\(position.isPod ? " (\(position.index)/\(position.total))" : "")")
        for vendor in ad.extensions {
            // Handed over verbatim (§3.18): the SDK assigns vendor XML no meaning,
            // so this is the only place its content is ever visible.
            screen.note("  ext \(vendor.type ?? "—") · \(vendor.xml)")
        }
        if screen.scenario.hostDrawsUI {
            screen.note("  sdk ui suppressed · \(session.suppressesAdUI)")
        }
    }

    func session(_ session: VASTAdSession, skipDidBecomeAvailableFor ad: VASTAd) {
        screen.note("skip available")
    }

    func session(_ session: VASTAdSession, didFinish ad: VASTAd, outcome: VASTAdSession.Outcome) {
        screen.note("finished \(ad.id) · \(outcome)")
    }

    /// One ad failing does not end a pod — the session moves to the next ad.
    func session(_ session: VASTAdSession, didFail error: VASTError, for ad: VASTAd?) {
        screen.note("error \(error.rawValue) on \(ad?.id ?? "-")")
    }

    func session(_ session: VASTAdSession, skipControlUnavailableFor ad: VASTAd, reason: String) {
        screen.note("⚠︎ skip control unavailable · \(reason)")
    }

    /// Reported on tvOS for a `.surface` click, and on every platform once an ad
    /// is playing in a window the click layer is not over.
    func session(_ session: VASTAdSession, clickThroughUnavailableFor ad: VASTAd, reason: String) {
        screen.note("⚠︎ click path unavailable · \(reason)")
    }
}

// MARK: - Skip pill

/// The UIKit twin of `DemoSkipButton`.
///
/// Used twice over: handed to the SDK through `skipButtonBuilder`, and drawn by
/// the screen itself for the scenario whose response asks the player to draw
/// nothing. The same control either way, so the two paths look alike on purpose.
final class SkipPill: UIControl {

    /// Seconds until the control unlocks, or `nil` once it has.
    var secondsUntilUnlock: TimeInterval? {
        didSet { apply() }
    }

    /// Whether the focus engine may land on this pill.
    ///
    /// tvOS has no tap, so a control the focus engine cannot reach is a control
    /// that does not exist — and `UIControl` is not focusable by default, only
    /// `UIButton` is. That is why the SDK wraps a host-supplied skip view in a
    /// `Button` before drawing it, and why the pill this screen places itself —
    /// with no such wrapper — has to take focus on its own.
    ///
    /// Left `false` for the pill handed to `skipButtonBuilder`: it is already
    /// inside the SDK's `Button`, and a second focus item nested in the first is
    /// not something the focus engine should have to resolve.
    var takesFocus = false

    private let icon = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 4
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        icon.contentMode = .scaleAspectFit
        label.font = .systemFont(ofSize: 12, weight: .bold)

        #if !os(tvOS)
        // A plain `UIControl` sends touch events and nothing else — only
        // `UIButton` turns a tap into `.primaryActionTriggered`. Relaying it here
        // gives the pill one contract on every platform: tvOS raises the same
        // action from the remote's select in `pressesEnded`, so a host registers
        // for `.primaryActionTriggered` once and it works everywhere.
        addTarget(self, action: #selector(relayTap), for: .touchUpInside)
        #endif

        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            // `VASTSurfacePresence.minimumUsableEdge`. At 8pt padding this drew
            // 50×31, and the SDK reported it as too small to hit — correctly.
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if !os(tvOS)
    @objc private func relayTap() {
        sendActions(for: .primaryActionTriggered)
    }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    #if os(tvOS)
    override var canBecomeFocused: Bool { takesFocus && isEnabled }

    /// The remote's select button. `.primaryActionTriggered` is what the rest of
    /// this screen listens for, so it is what the press has to turn into.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }), isEnabled {
            sendActions(for: .primaryActionTriggered)
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    /// Focus has to be visible or the viewer cannot tell what select will do.
    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations {
            self.transform = focused ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
            self.layer.borderWidth = focused ? 3 : 0
            self.layer.borderColor = UIColor.white.cgColor
        }
    }
    #endif

    private func apply() {
        if let secondsUntilUnlock {
            let tint = UIColor.white.withAlphaComponent(0.75)
            backgroundColor = UIColor.black.withAlphaComponent(0.55)
            icon.image = UIImage(systemName: "hourglass")
            icon.tintColor = tint
            label.textColor = tint
            label.text = "\(Int(secondsUntilUnlock.rounded(.up)))"
            isEnabled = false
        } else {
            backgroundColor = .systemYellow
            icon.image = UIImage(systemName: "forward.end.fill")
            icon.tintColor = .black
            label.textColor = .black
            // The host's own copy. A host replacing the control takes its
            // wording over too — the SDK's own default is localised separately.
            label.text = "Skip"
            isEnabled = true
        }
    }
}

#endif
