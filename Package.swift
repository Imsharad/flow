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
        // Core Audio Tap
        // .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"), // Example if needed
        
        // Inference Engine: WhisperKit (CoreML)
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        
        // Inference Engine: MLX (Unicorn Stack)
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.10.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "GhostType",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift")
            ],
            resources: [
                .process("Resources/t5_vocab.json"),
                .copy("Resources/mlx-distil-large-v3"),
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
