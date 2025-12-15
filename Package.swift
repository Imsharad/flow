// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GhostType",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GhostType", targets: ["GhostType"])
    ],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", from: "1.10.0")
    ],
    targets: [
        .executableTarget(
            name: "GhostType",
            dependencies: [
                .product(name: "SherpaOnnx", package: "sherpa-onnx")
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "GhostTypeTests",
            dependencies: ["GhostType"]
        ),
    ]
)
