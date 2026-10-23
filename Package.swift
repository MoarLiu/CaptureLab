// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptureLab",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CaptureLab", targets: ["CaptureLab"]),
        .executable(name: "CaptureLabUpdateSwap", targets: ["CaptureLabUpdateSwap"])
    ],
    targets: [
        .executableTarget(
            name: "CaptureLab",
            path: "Sources/CaptureLab",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "CaptureLabUpdateSwap",
            path: "Sources/CaptureLabUpdateSwap"
        ),
        // Test-support executable (also built by an unfiltered swift build).
        // Packaging selects the app products and never embeds this fixture.
        .executableTarget(
            name: "CaptureLabHistoryLockFixture",
            path: "Tests/HistoryLockFixture"
        ),
        .testTarget(
            name: "CaptureLabTests",
            dependencies: ["CaptureLab", "CaptureLabUpdateSwap", "CaptureLabHistoryLockFixture"],
            path: "Tests/CaptureLabTests"
        )
    ]
)
