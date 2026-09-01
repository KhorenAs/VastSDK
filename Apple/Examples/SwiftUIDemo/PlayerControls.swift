//
//  PlayerControls.swift
//  SwiftUIDemo
//

import SwiftUI

/// Transport controls for the content stream.
///
/// Hidden entirely while an ad is on screen — the scrubber must not exist during
/// a linear creative, and hiding it is clearer to the viewer than disabling it.
struct ContentControls: View {

    @ObservedObject var model: ContentPlayerModel

    var body: some View {
        VStack(spacing: 8) {
            scrubber
            HStack(spacing: 20) {
                #if !os(tvOS)
                Button { model.step(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                #endif

                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }

                #if !os(tvOS)
                Button { model.step(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                #endif

                Spacer()

                if model.isBuffering {
                    // `controlSize` is unavailable on tvOS, where the default
                    // indicator is the right size anyway.
                    #if os(tvOS)
                    ProgressView()
                    #else
                    ProgressView().controlSize(.small)
                    #endif
                }
                Text("\(ContentPlayerModel.timecode(model.currentTime)) / \(ContentPlayerModel.timecode(model.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// tvOS has no pointer to drag with, so it gets a read-only progress bar and
    /// relies on the remote's transport buttons instead.
    @ViewBuilder
    private var scrubber: some View {
        #if os(tvOS)
        ProgressView(value: model.progress)
            .progressViewStyle(.linear)
        #else
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: width * model.progress)
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .offset(x: width * model.progress - 6)
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.scrub(toProgress: value.location.x / width)
                    }
                    .onEnded { _ in
                        model.commitScrub()
                    }
            )
        }
        .frame(height: 12)
        #endif
    }
}

/// A branded skip control, handed to `VASTAdSurface.vastSkipButton`.
///
/// Shows the point of the styling hooks: the SDK still decides *when* a skip is
/// offered — which is the part §2.3 cares about — while the host decides what it
/// looks like.
struct DemoSkipButton: View {

    /// Seconds until the control unlocks, or `nil` once it has.
    let secondsUntilUnlock: TimeInterval?

    var body: some View {
        Group {
            if let secondsUntilUnlock {
                Label("\(Int(secondsUntilUnlock.rounded(.up)))", systemImage: "hourglass")
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Label("Skip", systemImage: "forward.end.fill")
                    .foregroundStyle(.black)
            }
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 14)
        // 44pt is `VASTSurfacePresence.minimumUsableEdge`, and the SDK reports a
        // control drawn smaller than that — correctly: this one was 50×31, below
        // the platform's own minimum hit target.
        .frame(minWidth: 44, minHeight: 44)
        .background(secondsUntilUnlock == nil ? .yellow : .black.opacity(0.55), in: Capsule())
    }
}
