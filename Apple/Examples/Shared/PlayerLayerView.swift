//
//  PlayerLayerView.swift
//  VASTDemo
//

import SwiftUI
import AVFoundation

/// A bare `AVPlayerLayer`, with no system controls of its own.
///
/// `VideoPlayer` and `AVPlayerViewController` bring Apple's transport controls,
/// which offer a scrubber. During an ad that scrubber is a problem: VAST has no
/// concept of seeking inside a linear creative, and the tracking engine treats
/// any jump as unwatched time. Owning the surface means the host decides when a
/// scrubber exists at all.
struct PlayerLayerView {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
}

#if os(macOS)

import AppKit

extension PlayerLayerView: NSViewRepresentable {

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.attach(player: player, gravity: gravity)
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.attach(player: player, gravity: gravity)
    }
}

final class PlayerHostView: NSView {

    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func attach(player: AVPlayer, gravity: AVLayerVideoGravity) {
        playerLayer.player = player
        playerLayer.videoGravity = gravity
    }
}

#else

import UIKit

extension PlayerLayerView: UIViewRepresentable {

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.attach(player: player, gravity: gravity)
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.attach(player: player, gravity: gravity)
    }
}

final class PlayerHostView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func attach(player: AVPlayer, gravity: AVLayerVideoGravity) {
        playerLayer.player = player
        playerLayer.videoGravity = gravity
    }
}

#endif
