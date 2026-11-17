// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Wenku8iOS",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Wenku8iOS",
            targets: ["Wenku8iOS"]
        ),
        .library(
            name: "Wenku8Core",
            targets: ["Wenku8Core"]
        ),
    ],
    targets: [
        .target(
            name: "Wenku8Core",
            resources: [
                .copy("Resources/gbk-table.bin"),
            ]
        ),
        .target(
            name: "Wenku8iOS",
            dependencies: ["Wenku8Core"]
        ),
        .testTarget(
            name: "Wenku8CoreTests",
            dependencies: ["Wenku8Core"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
