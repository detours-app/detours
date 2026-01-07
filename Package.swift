// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Detour",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Detour",
            path: "src"
        ),
        .testTarget(
            name: "DetourTests",
            dependencies: ["Detour"],
            path: "Tests",
            exclude: ["TEST_LOG.md"]
        ),
    ]
)
