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
        // Dependencies declare other packages that this package depends on.
        // Bumped to 1.10.0 for Moonshine support
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", from: "1.10.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "GhostType",
            dependencies: [
                .product(name: "sherpa-onnx", package: "sherpa-onnx")
            ],
            resources: [
                .process("Resources")
            ],
            infoPlist: .extendingDefault(with: [
                "NSMicrophoneUsageDescription": "GhostType needs access to your microphone to listen to your voice command."
            ])
        ),
        .testTarget(
            name: "GhostTypeTests",
            dependencies: ["GhostType"]),
    ]
)
