// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Detours",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Detours",
            path: "src"
        ),
        .testTarget(
            name: "DetoursTests",
            dependencies: ["Detours"],
            path: "Tests",
            exclude: ["TEST_LOG.md"]
        ),
    ]
)
