// swift-tools-version: 6.2

import Foundation
import PackageDescription

let detoursSwiftSettings: [SwiftSetting] = {
    guard ProcessInfo.processInfo.environment["DETOURS_SCREENSHOT_FIXTURES"] == "1" else {
        return []
    }
    return [.define("DETOURS_SCREENSHOT_FIXTURES")]
}()

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
            path: "src",
            swiftSettings: detoursSwiftSettings
        ),
        .executableTarget(
            name: "detours-server",
            path: "Server"
        ),
        .testTarget(
            name: "DetoursTests",
            dependencies: ["Detours", "detours-server"],
            path: "Tests",
            exclude: ["TEST_LOG.md", "UITests"]
        ),
    ]
)
