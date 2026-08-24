//
//  AdBreakViewController.swift
//  UIKitDemo
//

#if canImport(UIKit) && !os(watchOS)

import UIKit
import AVKit
import VASTCore
import VASTKit

/// UIKit host. Same session type as the SwiftUI demo; the difference is that
/// state arrives through `iVASTAdSessionDelegate` rather than `@Published`, so
/// no ObservableObject is involved.
final class AdBreakViewController: UIViewController {

    private let scenario: DemoScenario
    private let player = AVPlayer()
    private lazy var playerController = AVPlayerViewController()
    private lazy var session = VASTAdSession(player: player)

    private let logView = UITextView()

    init(scenario: DemoScenario) {
        self.scenario = scenario
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = scenario.title
        #if os(iOS)
        view.backgroundColor = .systemBackground
        #endif
        embedPlayer()
        session.delegate = self

        // The SDK adds its own ad UI — countdown, pod position, skip control and
        // tap-to-click — into whatever container it is given.
        if let overlay = playerController.contentOverlayView {
            session.attach(to: overlay)
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: DemoCatalog.contentStream))
        player.play()

        Task {
            // `try?` would swallow the cancellation SwiftUI/UIKit raises when the
            // screen is dismissed, and execution would carry on into the break —
            // playing an ad, and holding this controller alive, with no screen.
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await runAdBreak()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stop()
        session.detach()
        player.pause()
    }

    // MARK: - Layout

    private func embedPlayer() {
        playerController.player = player
        playerController.showsPlaybackControls = false
        addChild(playerController)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)

        #if os(iOS)
        logView.isEditable = false
        #endif
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logView)

        NSLayoutConstraint.activate([
            playerController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerController.view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9.0 / 16.0),

            logView.topAnchor.constraint(equalTo: playerController.view.bottomAnchor),
            logView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            logView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            logView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: - Actions

    private func runAdBreak() async {
        note("load \(scenario.id)")
        do {
            switch scenario.source {
            case .tag(let url): try await session.load(tag: url)
            case .xml(let xml): try await session.load(xml: xml)
            }
        } catch let error as VASTError {
            note("failed · VAST \(error.rawValue) \(error)")
            return
        } catch {
            note("failed · \(error)")
            return
        }
        let outcome = await session.play()
        note("break finished · \(outcome)")
    }

    private func note(_ line: String) {
        logView.text += line + "\n"
    }
}

extension AdBreakViewController: iVASTAdSessionDelegate {

    func session(_ session: VASTAdSession, didStart ad: VASTAd, at position: VASTAdSession.AdPosition) {
        note("start \(ad.id)\(position.isPod ? " (\(position.index)/\(position.total))" : "")")
    }

    func session(_ session: VASTAdSession, skipDidBecomeAvailableFor ad: VASTAd) {
        note("skip available")
    }

    func session(_ session: VASTAdSession, didFinish ad: VASTAd, outcome: VASTAdSession.Outcome) {
        note("finished \(ad.id) · \(outcome)")
    }

    /// One ad failing does not end a pod — the session moves to the next ad.
    func session(_ session: VASTAdSession, didFail error: VASTError, for ad: VASTAd?) {
        note("error \(error.rawValue) on \(ad?.id ?? "-")")
    }

    func sessionDidFinishAllAds(_ session: VASTAdSession) {
        note("content resumed")
    }
}

#endif
