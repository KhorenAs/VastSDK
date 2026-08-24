//
//  AdBreakWindowController.swift
//  AppKitDemo
//

#if os(macOS)

import AppKit
import AVKit
import VASTCore
import VASTKit

/// AppKit host. Included because Google's IMA SDK has no macOS build at all —
/// on the Mac a native VAST implementation is the only option, not a preference.
@MainActor
final class AdBreakWindowController: NSWindowController {

    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private lazy var session = VASTAdSession(player: player)



    convenience init(scenario: DemoScenario) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VAST AppKit Demo"
        self.init(window: window)
        self.scenario = scenario
        configure()
    }

    private var scenario: DemoScenario?

    private func configure() {
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(playerView)
        window?.contentView = content

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        // The SDK owns the ad UI on every platform, including this one.
        session.attach(to: content)

        session.delegate = self
        player.replaceCurrentItem(with: AVPlayerItem(url: DemoCatalog.contentStream))
        player.play()

        Task {
            guard let scenario else { return }
            // Let the content settle first, so swapping to the ad and returning
            // afterwards are both visible. Not `try?`: swallowing the cancellation
            // raised when the window closes would carry on into the break.
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            do {
                switch scenario.source {
                case .tag(let url): try await session.load(tag: DemoCatalog.requestReady(url))
                case .xml(let xml): try await session.load(xml: xml)
                }
                await session.play()
            } catch {
                print("ad break failed:", error)
            }
        }
    }

}

extension AdBreakWindowController: iVASTAdSessionDelegate {

    func session(_ session: VASTAdSession, didStart ad: VASTAd, at position: VASTAdSession.AdPosition) {
        print("start \(ad.id)")
    }

    func session(_ session: VASTAdSession, skipDidBecomeAvailableFor ad: VASTAd) {
        print("skip available")
    }

    func sessionDidFinishAllAds(_ session: VASTAdSession) {
        print("content resumed")
    }
}

#endif
