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
        .testTarget(
            name: "CaptureLabTests",
            dependencies: ["CaptureLab", "CaptureLabUpdateSwap"],
            path: "Tests/CaptureLabTests"
        )
    ]
)
