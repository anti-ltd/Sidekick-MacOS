// swift-tools-version: 6.1
import PackageDescription

// Sidekick (macOS) — remote desktop with deep-integration extras.
//
// The Mac app is dual-mode: host (its screen + input are shared) and client
// (it drives another Mac). It links iUX for chrome and links its own core
// library, so that core can be embedded into other host apps later or driven
// from a CLI for testing.
let package = Package(
    name: "Sidekick",
    platforms: [.macOS("26.0")],
    products: [
        // Embeddable core — every business-logic surface (transport, discovery,
        // capture, input, RPC). No icon, no menu-bar item.
        .library(name: "SidekickCore", targets: ["SidekickCore"]),
        // Standalone Sidekick.app — built via `make app`.
        .executable(name: "Sidekick", targets: ["Sidekick"]),
    ],
    dependencies: [
        // Shared macOS UX layer — settings popover, menu-bar host, glass chrome.
        .package(path: "../iUX"),
        // WebRTC — prebuilt Chromium WebRTC framework as a SwiftPM binary
        // dependency. Versions track Chromium milestones, so each major is a
        // potentially breaking step; pin tight on update and bump deliberately.
        //
        // Capped below 147 because that release ships a broken macOS slice
        // (umbrella WebRTC.h references RTCAudioSource.h et al. which aren't
        // present in macos-x86_64_arm64). Upstream issue stasel/WebRTC#145.
        .package(url: "https://github.com/stasel/WebRTC", "146.0.0"..<"147.0.0"),
    ],
    targets: [
        // All business logic. Transport, discovery, capture, injection, RPC.
        .target(
            name: "SidekickCore",
            dependencies: [
                "iUX",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/SidekickCore"
        ),
        // Standalone entry point: AppDelegate, main window, icon renderer.
        .executableTarget(
            name: "Sidekick",
            dependencies: ["SidekickCore", "iUX"],
            path: "Sources/Sidekick"
        ),
        .testTarget(
            name: "SidekickCoreTests",
            dependencies: ["SidekickCore"],
            path: "Tests/SidekickCoreTests"
        ),
    ]
)
