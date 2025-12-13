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
                .process("Resources")
            ]
        ),
    ]
)
