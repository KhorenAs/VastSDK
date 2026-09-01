//
//  LiveSession.swift
//  Harness
//
//  Runs a real VASTAdSession against a real creative, on macOS, printing the
//  published state as it changes. Exists because a frozen countdown in the demo
//  app cannot be told apart from a frozen clock without watching both.
//

import Foundation
import AVFoundation
import VASTCore
import VASTKit

@MainActor
func runLiveSession(xml: String) async {
    let player = AVPlayer()
    let session = VASTAdSession(player: player)

    do {
        try await session.load(xml: xml)
    } catch {
        print("load failed: \(error)")
        return
    }
    print("resolved \(session.adPosition.total) ad(s)")

    // Sample the published state independently of the session's own loop, so a
    // stalled loop shows up as an unchanging sample rather than as no output.
    let sampler = Task { @MainActor in
        for step in 0..<24 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            print(String(
                format: "%5.1fs  state=%-12@ remaining=%5.1f  skipIn=%@  canSkip=%@",
                Double(step) * 0.5,
                String(describing: session.state) as NSString,
                session.remainingTime,
                session.timeUntilSkip.map { String(format: "%.1f", $0) } ?? "—",
                session.canSkip ? "yes" : "no"
            ))
        }
    }

    let outcome = await session.play()
    sampler.cancel()
    print("outcome: \(outcome)")
}
