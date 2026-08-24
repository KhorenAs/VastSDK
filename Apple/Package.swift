// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VASTSDK",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "VASTKit", targets: ["VASTKit"]),
        .library(name: "VASTCore", targets: ["VASTCore"]),
    ],
    targets: [
        // Pure logic. Deliberately does NOT link AVFoundation or SwiftUI, so the
        // parsing and tracking rules can never take a dependency on a live player.
        .target(name: "VASTCore"),

        // Player, networking and UI binding.
        .target(name: "VASTKit", dependencies: ["VASTCore"]),

        // Runnable logic harness for VASTCore: `swift run Harness`.
        // Drives the tracking engine with scripted ticks — no player, no network.
        .executableTarget(name: "Harness", dependencies: ["VASTCore", "VASTKit"]),

        // Example apps live in Examples/VASTDemo.xcodeproj as real app
        // targets, one scheme per platform.

        .testTarget(
            name: "VASTCoreTests",
            dependencies: ["VASTCore"],
            resources: [.copy("Fixtures")]
        ),

        .testTarget(name: "VASTKitTests", dependencies: ["VASTKit"]),
    ],
    swiftLanguageModes: [.v6]
)
