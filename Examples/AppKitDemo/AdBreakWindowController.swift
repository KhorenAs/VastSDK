//
//  AdBreakWindowController.swift
//  AppKitDemo
//

#if os(macOS)

import AppKit
import Combine
import AVFoundation
import VASTCore
import VASTKit

/// AppKit host. Included because Google's IMA SDK has no macOS build at all — on
/// the Mac a native VAST implementation is the only option, not a preference.
///
/// Laid out to match the SwiftUI demo's player screen section for section:
/// header, 16:9 player with the ad surface over it, the content transport
/// (replaced by a notice while an ad owns the player), the break action with a
/// state label, and the event log. The behaviour is not written twice —
/// `AdBreakScreen` is the same model the SwiftUI screen drives, so only the
/// pixels are.
@MainActor
final class AdBreakWindowController: NSWindowController {

    private let screen: AdBreakScreen
    private let playerView = PlayerHostView()
    /// Handed back by `attach(to:)`, which is also what keeps it front-most.
    private var adSurface: VASTAdSurfaceView?

    private var cancellables: Set<AnyCancellable> = []
    private var breakTask: Task<Void, Never>?

    // Header
    private let titleLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")

    // Transport, and the notice that stands in for it during a break
    private let transport = NSStackView()
    private let adNotice = NSTextField(labelWithString: "Content controls are unavailable during an ad")
    private let scrubber = NSSlider()
    private let playPause = NSButton()
    private let back10 = NSButton()
    private let forward10 = NSButton()
    private let timecode = NSTextField(labelWithString: "")
    private let buffering = NSProgressIndicator()

    // Actions and log
    private let breakButton = NSButton()
    private let stateLabel = NSTextField(labelWithString: "")
    private let logView = NSTextView()

    /// The window's own skip control, for the scenario whose response asks the
    /// player to draw nothing. The same pill the SDK is handed, drawn by the host
    /// instead — which is what makes the two paths comparable at a glance.
    private lazy var hostSkip: SkipPill = {
        let pill = SkipPill()
        pill.onClick = { [weak self] in self?.skipTapped() }
        pill.isHidden = true
        return pill
    }()

    init(scenario: DemoScenario) {
        self.screen = AdBreakScreen(scenario: scenario)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = scenario.title
        super.init(window: window)
        buildLayout()
        screen.session.delegate = self
        observe()
        render()

        // Held so it can be cancelled when the window closes. A break left running
        // would keep the window's player alive — audible, with nothing on screen
        // left to stop it.
        breakTask = Task { [screen] in await screen.start() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func buildLayout() {
        titleLabel.stringValue = screen.scenario.title
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        sourceLabel.stringValue = sourceDescription
        sourceLabel.font = .preferredFont(forTextStyle: .caption1)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingMiddle

        let header = NSStackView(views: [titleLabel, sourceLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        playerView.attach(player: screen.player, gravity: .resizeAspect)
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
        playerView.addSubview(hostSkip, positioned: .above, relativeTo: nil)
        hostSkip.translatesAutoresizingMaskIntoConstraints = false

        buildTransport()

        let divider = NSBox()
        divider.boxType = .separator

        breakButton.bezelStyle = .rounded
        breakButton.target = self
        breakButton.action = #selector(breakTapped)
        stateLabel.font = .preferredFont(forTextStyle: .caption1)
        stateLabel.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [breakButton, NSView(), stateLabel])
        actions.orientation = .horizontal
        actions.distribution = .fill

        logView.isEditable = false
        logView.drawsBackground = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.documentView = logView

        let column = NSStackView(
            views: [header, playerView, transport, adNotice, divider, actions, logScroll]
        )
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false

        // All the slack goes to the log — see the UIKit screen for what happens
        // when every row hugs at the same priority on a large surface.
        for row in [header, transport, adNotice, actions] {
            row.setContentHuggingPriority(.required, for: .vertical)
        }
        logView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        logScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let content = NSView(frame: window?.contentLayoutRect ?? .zero)
        content.addSubview(column)
        window?.contentView = content

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            playerView.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            playerView.heightAnchor.constraint(equalTo: playerView.widthAnchor, multiplier: 9.0 / 16.0),

            hostSkip.trailingAnchor.constraint(equalTo: playerView.trailingAnchor, constant: -16),
            hostSkip.bottomAnchor.constraint(equalTo: playerView.bottomAnchor, constant: -16),

            transport.widthAnchor.constraint(equalTo: playerView.widthAnchor),
            adNotice.heightAnchor.constraint(equalToConstant: 40),
            actions.widthAnchor.constraint(equalTo: playerView.widthAnchor),
            logScroll.widthAnchor.constraint(equalTo: playerView.widthAnchor),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    /// The content transport, and the notice that replaces it. Hidden rather than
    /// disabled during a break: a scrubber must not exist while a linear creative
    /// is on screen, and hiding says so more clearly than greying out.
    private func buildTransport() {
        adNotice.font = .preferredFont(forTextStyle: .caption1)
        adNotice.textColor = .secondaryLabelColor
        adNotice.alignment = .center

        scrubber.minValue = 0
        scrubber.maxValue = 1
        scrubber.isContinuous = true
        scrubber.target = self
        scrubber.action = #selector(scrubbing)

        configure(playPause, symbol: "play.fill", action: #selector(togglePlayPause))
        configure(back10, symbol: "gobackward.10", action: #selector(stepBack))
        configure(forward10, symbol: "goforward.10", action: #selector(stepForward))

        timecode.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timecode.textColor = .secondaryLabelColor

        buffering.style = .spinning
        buffering.controlSize = .small
        buffering.isDisplayedWhenStopped = false

        let buttons = NSStackView(views: [back10, playPause, forward10, NSView(), buffering, timecode])
        buttons.orientation = .horizontal
        buttons.spacing = 16
        buttons.alignment = .centerY

        transport.orientation = .vertical
        transport.alignment = .leading
        transport.spacing = 8
        transport.addArrangedSubview(scrubber)
        transport.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            scrubber.widthAnchor.constraint(equalTo: transport.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: transport.widthAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.target = self
        button.action = action
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
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }
                .store(in: &cancellables)
        }
    }

    private func render() {
        let isPlayingAd = screen.isPlayingAd
        transport.isHidden = isPlayingAd
        adNotice.isHidden = !isPlayingAd

        scrubber.doubleValue = screen.content.progress
        playPause.image = NSImage(
            systemSymbolName: screen.content.isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )
        timecode.stringValue = ContentPlayerModel.timecode(screen.content.currentTime)
            + " / " + ContentPlayerModel.timecode(screen.content.duration)
        if screen.content.isBuffering {
            buffering.startAnimation(nil)
        } else {
            buffering.stopAnimation(nil)
        }

        renderBreakButton()
        stateLabel.stringValue = stateDescription

        let text = screen.log.joined(separator: "\n")
        if logView.string != text {
            logView.string = text
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

    /// One button, four meanings — a label reading "Replay" before anything has
    /// played, or clickable while a response is still loading, describes a state
    /// the session is not in.
    private func renderBreakButton() {
        switch screen.session.state {
        case .loading:
            breakButton.title = "Loading…"
            breakButton.isEnabled = false
            breakButton.hasDestructiveAction = false

        case .playing, .paused:
            // Deliberately an action rather than a gap: this is the teardown path
            // that used to leave an abandoned ad still audible.
            breakButton.title = "Stop ad break"
            breakButton.isEnabled = true
            breakButton.hasDestructiveAction = true

        case .idle, .finished:
            breakButton.title = screen.hasPlayedOnce ? "Replay ad break" : "Play ad break"
            breakButton.isEnabled = !screen.isBusy
            breakButton.hasDestructiveAction = false
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
            screen.session.stop()
        case .idle, .finished:
            Task { [screen] in await screen.runBreak() }
        case .loading:
            break
        }
    }

    private func skipTapped() {
        do { try screen.session.skip() } catch { screen.note("skip refused · \(error)") }
    }

    @objc private func togglePlayPause() { screen.content.togglePlayPause() }
    @objc private func stepBack() { screen.content.step(by: -10) }
    @objc private func stepForward() { screen.content.step(by: 10) }

    /// `NSSlider` reports every step of a drag through one action, so the end of
    /// the drag has to be read from the event that caused it — otherwise the
    /// content is seeked hundreds of times instead of once.
    @objc private func scrubbing() {
        screen.content.scrub(toProgress: scrubber.doubleValue)
        if window?.currentEvent?.type == .leftMouseUp {
            screen.content.commitScrub()
        }
    }

    // MARK: - Teardown

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.delegate = self
    }
}

extension AdBreakWindowController: NSWindowDelegate {

    /// Closing the window is this host's "screen went away".
    func windowWillClose(_ notification: Notification) {
        breakTask?.cancel()
        screen.invalidate()
    }
}

// MARK: - Session delegate

/// The log lines the SwiftUI screen reads out of `@Published` state, this window
/// gets from the delegate — the same events, arriving the other way round.
extension AdBreakWindowController: iVASTAdSessionDelegate {

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
}

// MARK: - Skip pill

/// The AppKit twin of `DemoSkipButton`.
///
/// Used twice over: handed to the SDK through `skipButtonBuilder`, and drawn by
/// the window itself for the scenario whose response asks the player to draw
/// nothing. The same control either way, so the two paths look alike on purpose.
final class SkipPill: NSView {

    /// Seconds until the control unlocks, or `nil` once it has.
    var secondsUntilUnlock: TimeInterval? {
        didSet { apply() }
    }

    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        icon.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 12, weight: .bold)

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

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func mouseDown(with event: NSEvent) {
        guard secondsUntilUnlock == nil else { return }
        onClick?()
    }

    private func apply() {
        if let secondsUntilUnlock {
            let tint = NSColor.white.withAlphaComponent(0.75)
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            icon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
            icon.contentTintColor = tint
            label.textColor = tint
            label.stringValue = "\(Int(secondsUntilUnlock.rounded(.up)))"
        } else {
            layer?.backgroundColor = NSColor.systemYellow.cgColor
            icon.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
            icon.contentTintColor = .black
            label.textColor = .black
            // The host's own copy; the SDK's own default is localised separately.
            label.stringValue = "Skip"
        }
    }
}

#endif
