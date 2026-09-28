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
            name: "GigaAMKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Numerics", package: "swift-numerics")
            ],
            path: "Sources/GigaAMKit"
        ),
        .testTarget(
            name: "GigaAMKitTests",
            dependencies: ["GigaAMKit"],
            path: "Tests/GigaAMKitTests"
        ),
        .executableTarget(
            name: "Srez",
            dependencies: ["GigaAMKit"]
        ),
        .testTarget(
            name: "SrezTests",
            dependencies: ["Srez"]
        )
    ]
)
