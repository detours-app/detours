// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Detours",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Detours", targets: ["Detours"]),
        .executable(name: "detours-server", targets: ["detours-server"]),
    ],
    targets: [
        .executableTarget(
            name: "Detours",
            path: "src"
        ),
        .executableTarget(
            name: "detours-server",
            path: "Server"
        ),
        .testTarget(
            name: "DetoursTests",
            dependencies: ["Detours"],
            path: "Tests",
            exclude: ["TEST_LOG.md", "UITests"]
        ),
    ]
)
