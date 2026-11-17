#!/usr/bin/env bash
# Builds and tests the platform-independent Wenku8Core module.
#
# SwiftUI only exists on Apple platforms, so the app target cannot be compiled
# on Linux. This script builds a scratch package that contains only the core
# module and its tests, which is enough to catch parser and networking errors
# on any machine with a Swift toolchain (including CI containers).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
SCRATCH=".linux-scratch"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/Sources" "$SCRATCH/Tests"

cp -R Sources/Wenku8Core "$SCRATCH/Sources/Wenku8Core"
cp -R Tests/Wenku8CoreTests "$SCRATCH/Tests/Wenku8CoreTests"

cat > "$SCRATCH/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wenku8CoreLinux",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Wenku8Core", targets: ["Wenku8Core"]),
    ],
    targets: [
        .target(
            name: "Wenku8Core",
            resources: [.copy("Resources/gbk-table.bin")]
        ),
        .testTarget(
            name: "Wenku8CoreTests",
            dependencies: ["Wenku8Core"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
PACKAGE

cd "$SCRATCH"
swift test "$@"
