//
//  AdBreakView.swift
//  SwiftUIDemo
//

import SwiftUI
import VASTCore
import VASTKit

/// First screen: pick a scenario.
struct ScenarioListView: View {

    @ObservedObject private var liveCount = AdBreakScreen.LiveCount.shared
    @ObservedObject private var settings = DemoSettings.shared

    var body: some View {
        NavigationStack {
            List(DemoCatalog.scenarios) { scenario in
                NavigationLink(value: scenario) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scenario.title).font(.headline)
                        Text(scenario.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("VAST Demo")
            .navigationDestination(for: DemoScenario.self) { scenario in
                PlayerView(scenario: scenario)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    pictureInPicturePolicy
                    liveScreenCount
                }
                .padding(.top, 6)
                // `.bar` does not exist on tvOS, and this inset sits over a
                // scrolling list on every platform, so it needs *some* ground.
                .background(.regularMaterial)
            }
        }
    }

    /// Chosen here rather than on the player screen, because it is part of the
    /// session's configuration and the session is built when that screen opens.
    private var pictureInPicturePolicy: some View {
        VStack(spacing: 2) {
            Picker("Picture in Picture", selection: $settings.pictureInPictureIndex) {
                ForEach(DemoSettings.pictureInPictureLabels.indices, id: \.self) { index in
                    Text(DemoSettings.pictureInPictureLabels[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            Text("picture in picture during an ad · applies to the next screen")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Reads zero when no player screen is open. A number that stays above zero
    /// after backing out means a screen — and its player — is still alive, which
    /// is a far more useful thing to look at than guessing about a sound.
    private var liveScreenCount: some View {
        Text("live player screens: \(liveCount.value)")
            .font(.caption2.monospaced())
            .foregroundStyle(liveCount.value == 0 ? Color.secondary : Color.red)
            .padding(8)
    }
}

/// Second screen: content plays under the app's own controls, an ad break takes
/// the player over, and the content resumes where it was interrupted.
struct PlayerView: View {

    @StateObject private var screen: AdBreakScreen

    /// Nothing is built here. Everything the screen owns is created once, inside
    /// the `StateObject`, because SwiftUI re-runs a view's `init` on every redraw
    /// — and an `AVPlayer` built there is a new player each time.
    init(scenario: DemoScenario) {
        _screen = StateObject(wrappedValue: AdBreakScreen(scenario: scenario))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                PlayerLayerView(player: screen.player) { layer in
                    screen.adoptPlayerLayer(layer)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                VASTAdSurface(session: screen.session)
                    .vastSkipButton { remaining in
                        DemoSkipButton(secondsUntilUnlock: remaining)
                    }
                    .vastClickThrough { url in
                        screen.note(ClickThrough.open(url))
                    }
                hostDrawnSkip
            }
            .background(.black)

            // The content transport disappears for the duration of the break:
            // seeking inside a linear creative is not a thing VAST supports.
            // The session answers, rather than each demo keeping its own copy of
            // the rule — a host using AVKit hands over its player view controller
            // and does not even ask.
            if screen.session.permitsPlaybackControls {
                ContentControls(model: screen.content)
            } else {
                Text("Content controls are unavailable during an ad")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 62)
            }

            Divider()
            actions
            eventLog
        }
        .navigationTitle(screen.scenario.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await screen.start() }
        .onDisappear { screen.invalidate() }
    }

    /// The control this screen owes the viewer when the response asked the player
    /// to draw nothing and `isHiddenUi` allowed it. The SDK draws no skip in that
    /// case — by design — so §2.3 is honoured here or not at all.
    @ViewBuilder
    private var hostDrawnSkip: some View {
        if screen.session.suppressesAdUI, screen.isPlayingAd {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        try? screen.session.skip()
                    } label: {
                        DemoSkipButton(
                            secondsUntilUnlock: screen.session.canSkip
                                ? nil
                                : screen.session.timeUntilSkip
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!screen.session.canSkip)
                }
            }
            .padding()
        }
    }

    /// The scenario's own title, drawn in the page rather than left to the
    /// navigation bar: over a letterboxed black video the bar is invisible, and
    /// with six scenarios that look alike on screen, knowing which one is running
    /// is the whole point of the detail page.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(screen.scenario.title)
                .font(.headline)
            Text(sourceLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var sourceLabel: String {
        switch screen.scenario.source {
        case .tag(let url): "tag · \(url.host ?? url.absoluteString)"
        case .xml: "local response"
        }
    }

    private var actions: some View {
        HStack {
            breakButton
            pictureInPictureButton
            Spacer()
            Text(stateLabel).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Opens the window by hand. The other way in — leaving the app while an ad
    /// plays — needs no button at all, which is the case the policy exists for.
    ///
    /// Gone entirely while the session says the window is not on offer: under
    /// `.suspended` a press would open it and have it shut again, which is the
    /// right outcome reached the ugly way.
    @ViewBuilder
    private var pictureInPictureButton: some View {
        if screen.pictureInPicture != nil, screen.session.permitsPictureInPicture {
            Button(screen.isInPictureInPicture ? "Leave PiP" : "PiP") {
                screen.togglePictureInPicture()
            }
            .disabled(!screen.isPictureInPicturePossible)
        }
    }

    /// One button, four meanings — because a label that stays "Replay" while
    /// nothing has played yet, and stays tappable while a response is still
    /// loading, is describing a state the session is not in.
    @ViewBuilder
    private var breakButton: some View {
        switch screen.session.state {
        case .loading:
            Button("Loading…") {}
                .disabled(true)

        case .playing, .paused:
            // Deliberately an action rather than a gap: this is the teardown path
            // that used to leave an abandoned ad still audible.
            Button("Stop ad break", role: .destructive) { screen.session.stop() }

        case .idle, .finished:
            Button(screen.hasPlayedOnce ? "Replay ad break" : "Play ad break") {
                Task { await screen.runBreak() }
            }
            .disabled(screen.isBusy)
        }
    }

    private var eventLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(screen.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: screen.log.count) { count in
                proxy.scrollTo(count - 1)
            }
        }
        .frame(maxHeight: 160)
    }

    private var stateLabel: String {
        switch screen.session.state {
        case .idle: "idle"
        case .loading: "loading…"
        case .playing: "playing ad"
        case .paused: "paused"
        case .finished(let outcome): "finished · \(outcome)"
        }
    }
}
