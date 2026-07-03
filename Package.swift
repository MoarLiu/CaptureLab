// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptureLab",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CaptureLab", targets: ["CaptureLab"])
    ],
    targets: [
        .executableTarget(
            name: "CaptureLab",
            path: "Sources/CaptureLab",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "CaptureLabTests",
            dependencies: ["CaptureLab"],
            path: "Tests/CaptureLabTests"
        )
    ]
)
