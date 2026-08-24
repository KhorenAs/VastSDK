//
//  ScenarioListViewController.swift
//  UIKitDemo
//

#if canImport(UIKit) && !os(watchOS)

import UIKit

/// First screen: the same scenarios the SwiftUI demo offers, so the two hosts
/// can be compared behaviour for behaviour.
final class ScenarioListViewController: UITableViewController {

    private let scenarios = DemoCatalog.scenarios

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VAST Demo"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

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
