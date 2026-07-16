// swift-tools-version: 6.2

import Foundation
import PackageDescription

let detoursSwiftSettings: [SwiftSetting] = {
    var settings: [SwiftSetting] = [
        .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
    ]
    guard ProcessInfo.processInfo.environment["DETOURS_SCREENSHOT_FIXTURES"] == "1" else {
        return settings
    }
    settings.append(.define("DETOURS_SCREENSHOT_FIXTURES"))
    return settings
}()

let package = Package(
    name: "Detours",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Detours", targets: ["Detours"]),
        .executable(name: "detours-server", targets: ["detours-server"]),
        .library(name: "DetoursProcess", targets: ["DetoursProcess"]),
    ],
    targets: [
        .target(
            name: "DetoursProcess",
            path: "Shared",
            linkerSettings: [
                .linkedLibrary("util", .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(
            name: "Detours",
            dependencies: ["DetoursProcess"],
            path: "src",
            swiftSettings: detoursSwiftSettings
        ),
        .executableTarget(
            name: "detours-server",
            dependencies: ["DetoursProcess"],
            path: "Server"
        ),
        .testTarget(
            name: "DetoursTests",
            dependencies: ["Detours", "DetoursProcess", "detours-server"],
            path: "Tests",
            exclude: ["TEST_LOG.md", "UITests"]
        ),
        .testTarget(
            name: "DetoursProcessTests",
            dependencies: ["DetoursProcess"],
            path: "SharedTests"
        ),
    ]
)
