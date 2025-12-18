// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GhostType",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "GhostType",
            targets: ["GhostType"]),
    ],
    dependencies: [
        // Inference Engine: WhisperKit (CoreML)
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "GhostType",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
            // Note: Info.plist and GhostType.entitlements are in Resources/
            // but excluded from SwiftPM bundle (they're for Xcode/app bundle builds)
        ),
        .testTarget(
            name: "GhostTypeTests",
            dependencies: ["GhostType"]
        ),
    ]
)
