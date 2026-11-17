#!/usr/bin/env bash
# Runs the live smoke checks against wenku8.net using the real networking stack.
# Requires network access; run it from the repository root.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH=".smoke"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/Sources/Wenku8Core" "$SCRATCH/Sources/wenku8-smoke"

cp -R Sources/Wenku8Core/. "$SCRATCH/Sources/Wenku8Core/"
cp "$SCRATCH/Sources/Wenku8Core/Sources/Resources/gbk-table.bin" "$SCRATCH/Sources/Wenku8Core/gbk-table.bin" 2>/dev/null || true
cp -R "$SCRATCH/Sources/Wenku8Core/Resources" "$SCRATCH/Sources/Wenku8Core/Resources" 2>/dev/null || true
cp tools/smoke/main.swift "$SCRATCH/Sources/wenku8-smoke/main.swift"

# Flatten the copied tree: the core sources live at the package root here.
mv "$SCRATCH/Sources/Wenku8Core/Sources/"*.swift "$SCRATCH/Sources/Wenku8Core/" 2>/dev/null || true
rm -rf "$SCRATCH/Sources/Wenku8Core/Sources"

cat > "$SCRATCH/Sources/Wenku8Core/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wenku8Core",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Wenku8Core", targets: ["Wenku8Core"])],
    targets: [
        .target(
            name: "Wenku8Core",
            path: ".",
            exclude: ["Package.swift"],
            resources: [.copy("Resources/gbk-table.bin")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
PACKAGE

cat > "$SCRATCH/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wenku8Smoke",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Sources/Wenku8Core")],
    targets: [
        .executableTarget(
            name: "wenku8-smoke",
            dependencies: [.product(name: "Wenku8Core", package: "Wenku8Core")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
PACKAGE

cd "$SCRATCH"
swift run wenku8-smoke
