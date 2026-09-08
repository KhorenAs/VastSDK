// swift-tools-version: 6.0

import PackageDescription

// One manifest, in the one place SwiftPM looks for it.
//
// There were two: this and Apple/Package.swift, describing the same targets, with
// a note in the README saying that changing a target meant changing both. That
// note was the tell. The platform folder it existed to serve is gone — Android
// and Web get their own repositories rather than empty directories here — so the
// layout is now the conventional one and the manifest needs no `path:` at all.
let package = Package(
    name: "VASTSDK",
    defaultLocalization: "en",
    platforms: [
        .iOS("15.6"),
        .tvOS("15.6"),
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
        .target(
            name: "VASTKit",
            dependencies: ["VASTCore"],
            // The ad UI's own words, localised in the package, and the privacy
            // manifest: a host that configures nothing should get neither an
            // English skip control nor an undeclared SDK.
            resources: [.process("Resources")]
        ),

        // Runnable logic harness for VASTCore: `swift run Harness`.
        // Drives the tracking engine with scripted ticks — no player, no network.
        .executableTarget(name: "Harness", dependencies: ["VASTCore", "VASTKit"]),

        .testTarget(
            name: "VASTCoreTests",
            dependencies: ["VASTCore"],
            resources: [.copy("Fixtures")]
        ),

        .testTarget(name: "VASTKitTests", dependencies: ["VASTKit"]),
    ],
    swiftLanguageModes: [.v6]
)
