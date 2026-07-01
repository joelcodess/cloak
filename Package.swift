// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "cloak",
    platforms: [.macOS(.v26)],
    targets: [
        // Format-agnostic scrub/restore engine, shared by the CLI and the GUI app.
        .target(
            name: "CloakKit",
            path: "Sources/CloakKit"
        ),
        // CLI: scrub / rehydrate / doctor / proxy.
        .executableTarget(
            name: "cloak",
            dependencies: ["CloakKit"],
            path: "Sources/cloak"
        ),
        // Native SwiftUI document scrubber app.
        .executableTarget(
            name: "CloakApp",
            dependencies: ["CloakKit"],
            path: "Sources/CloakApp"
        ),
    ]
)
