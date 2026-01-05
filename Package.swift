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
    ]
)
