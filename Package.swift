// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Srez",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Srez",
            targets: ["Srez"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "GigaAM",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Numerics", package: "swift-numerics")
            ],
            path: "Sources/GigaAM"
        ),
        .testTarget(
            name: "GigaAMTests",
            dependencies: ["GigaAM"],
            path: "Tests/GigaAMTests"
        ),
        .executableTarget(
            name: "Srez",
            dependencies: ["GigaAM"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SrezTests",
            dependencies: ["Srez"]
        )
    ]
)
