//
//  ScenarioListViewController.swift
//  UIKitDemo
//

#if canImport(UIKit) && !os(watchOS)

import UIKit
import Combine

/// First screen: the same scenarios the SwiftUI demo offers, so the two hosts
/// can be compared behaviour for behaviour.
final class ScenarioListViewController: UITableViewController {

    private let scenarios = DemoCatalog.scenarios
    /// Reads zero when no player screen is open. A number that stays up means a
    /// screen — and its player — is still alive, which is far more useful than
    /// guessing about a sound. The SwiftUI list keeps the same figure.
    private let liveCount = UILabel()
    /// The same choice the SwiftUI list offers, in the same order. It is part of
    /// the session's configuration, so it has to be made before a player screen
    /// builds one.
    ///
    /// iOS only: tvOS has no `UISegmentedControl`, and no Picture in Picture
    /// button anywhere in this demo to pair it with.
    #if os(iOS)
    private lazy var pictureInPicture = UISegmentedControl(
        items: DemoSettings.pictureInPictureLabels
    )
    #endif
    private var cancellables: Set<AnyCancellable> = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VAST Demo"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        liveCount.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        liveCount.textAlignment = .center
        liveCount.frame = CGRect(x: 0, y: 0, width: 0, height: 28)
        tableView.tableFooterView = liveCount

        #if os(iOS)
        tableView.tableHeaderView = buildPictureInPictureHeader()
        #endif

        AdBreakScreen.LiveCount.shared.$value
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.liveCount.text = "live player screens: \(value)"
                self?.liveCount.textColor = value == 0 ? .secondaryLabel : .systemRed
            }
            .store(in: &cancellables)
    }

    #if os(iOS)
    private func buildPictureInPictureHeader() -> UIView {
        pictureInPicture.selectedSegmentIndex = DemoSettings.shared.pictureInPictureIndex
        pictureInPicture.addTarget(self, action: #selector(policyChanged), for: .valueChanged)

        let caption = UILabel()
        caption.text = "picture in picture during an ad · applies to the next screen"
        caption.font = .preferredFont(forTextStyle: .caption2)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.adjustsFontSizeToFitWidth = true

        let column = UIStackView(arrangedSubviews: [pictureInPicture, caption])
        column.axis = .vertical
        column.spacing = 4
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        // A table header sizes itself from its frame, not from constraints.
        column.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 72)
        column.autoresizingMask = [.flexibleWidth]
        return column
    }

    @objc private func policyChanged() {
        DemoSettings.shared.pictureInPictureIndex = pictureInPicture.selectedSegmentIndex
    }
    #endif

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        scenarios.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let scenario = scenarios[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = scenario.title
        content.secondaryText = scenario.detail
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let player = AdBreakViewController(scenario: scenarios[indexPath.row])
        navigationController?.pushViewController(player, animated: true)
    }
}

#endif
