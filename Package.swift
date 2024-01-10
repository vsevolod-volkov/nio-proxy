// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "nio-proxy",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "NIOProxy",
            targets: ["NIOProxy"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.42.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "NIOProxy",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "NIOProxyTests",
            dependencies: ["NIOProxy"]
        ),
    ]
)
