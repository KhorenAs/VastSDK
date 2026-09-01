//
//  AppKitDemoApp.swift
//  AppKitDemo
//

import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controllers: [AdBreakWindowController] = []
    private var picker: NSWindow?
    private let liveCount = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []

    /// Wires the delegate by hand rather than leaving it to `@main`.
    ///
    /// `@main` on an `NSApplicationDelegate` routes to `NSApplicationMain`, which
    /// expects the main nib to carry the delegate object. This target has no nib —
    /// `GENERATE_INFOPLIST_FILE` writes no `NSMainNibFile` — so nothing ever set
    /// `NSApp.delegate`, `applicationDidFinishLaunching` was never called, and the
    /// app launched into a default menu bar with no window at all.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // `NSApplication.delegate` is weak, and `run()` does not return until the
        // app quits, so this local is what keeps the delegate alive.
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showScenarioPicker()
        // Launched from Xcode or the Finder the app is activated for us; launched
        // any other way the window would open behind whatever was in front.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// First screen: pick a scenario, then it opens in its own player window.
    ///
    /// Laid out to match the SwiftUI demo's list — title, detail, and the live
    /// player-screen count along the bottom.
    private func showScenarioPicker() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        for (index, scenario) in DemoCatalog.scenarios.enumerated() {
            let button = NSButton(title: scenario.title, target: self, action: #selector(open(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            let detail = NSTextField(labelWithString: scenario.detail)
            detail.font = .preferredFont(forTextStyle: .caption1)
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(button)
            stack.addArrangedSubview(detail)
        }

        // Reads zero when no player window is open. A number that stays up means a
        // window — and its player — is still alive, which is far more useful than
        // guessing about a sound.
        liveCount.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        AdBreakScreen.LiveCount.shared.$value
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.liveCount.stringValue = "live player screens: \(value)"
                self?.liveCount.textColor = value == 0 ? .secondaryLabelColor : .systemRed
            }
            .store(in: &cancellables)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The stack goes inside a plain container rather than being the content
        // view itself. An auto-layout view handed straight to `contentView` takes
        // the window down to its own fitting size — 138×131 here, with most of the
        // list cut off — because the window sizes itself to fit it.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 620))
        content.addSubview(scroll)
        content.addSubview(liveCount)
        liveCount.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: liveCount.topAnchor, constant: -8),

            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            liveCount.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            liveCount.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VAST Demo"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        picker = window
    }

    @objc private func open(_ sender: NSButton) {
        let controller = AdBreakWindowController(scenario: DemoCatalog.scenarios[sender.tag])
        controller.showWindow(nil)
        controllers.append(controller)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
