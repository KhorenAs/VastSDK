// swift-tools-version: 6.0

import PackageDescription

// The Apple SDK lives in Apple/, alongside the Android and Web projects, but
// SwiftPM only ever looks for a manifest at the repository root — so a
// dependency on this repo's URL would not resolve without this file.
//
// It describes the same targets as Apple/Package.swift, reaching into Apple/ by
// path. That manifest stays where it is: Examples/VASTDemo.xcodeproj references
// it as a local package, and working inside Apple/ should not require thinking
// about the monorepo around it. Changing a target in one means changing it in
// both.

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
        .target(name: "VASTCore", path: "Apple/Sources/VASTCore"),

        // Player, networking and UI binding.
        .target(name: "VASTKit", dependencies: ["VASTCore"], path: "Apple/Sources/VASTKit"),

        // Runnable logic harness for VASTCore: `swift run Harness`.
        // Drives the tracking engine with scripted ticks — no player, no network.
        .executableTarget(
            name: "Harness",
            dependencies: ["VASTCore", "VASTKit"],
            path: "Apple/Sources/Harness"
        ),

        .testTarget(
            name: "VASTCoreTests",
            dependencies: ["VASTCore"],
            path: "Apple/Tests/VASTCoreTests",
            resources: [.copy("Fixtures")]
        ),

        .testTarget(
            name: "VASTKitTests",
            dependencies: ["VASTKit"],
            path: "Apple/Tests/VASTKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
