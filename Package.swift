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
        // Intentionally kept minimal; PRD requires CoreML-based models (no ONNX runtime).
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "GhostType",
            dependencies: [],
            resources: [
                // Use .copy for mlpackage directories to preserve structure
                // and avoid conflicts with internal files (model.mlmodel, etc.)
                .copy("Resources/MoonshineTiny.mlpackage"),
                .copy("Resources/T5Small.mlpackage"),
                .copy("Resources/T5Encoder.mlpackage"),
                .copy("Resources/T5Decoder.mlpackage"),
                .copy("Resources/EnergyVAD.mlpackage"),
                // Process JSON vocab files normally
                .process("Resources/moonshine_vocab.json"),
                .process("Resources/t5_vocab.json"),
                // Note: Info.plist and GhostType.entitlements are in Resources/
                // but excluded from SwiftPM bundle (they're for Xcode/app bundle builds)
            ]
        ),
        .testTarget(
            name: "GhostTypeTests",
            dependencies: ["GhostType"]
        ),
    ]
)
