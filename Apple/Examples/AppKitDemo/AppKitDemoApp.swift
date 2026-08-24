//
//  AppKitDemoApp.swift
//  AppKitDemo
//

import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controllers: [AdBreakWindowController] = []
    private var picker: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showScenarioPicker()
    }

    /// First screen: pick a scenario, then it opens in its own player window.
    private func showScenarioPicker() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VAST Demo"
        window.contentView = stack
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
