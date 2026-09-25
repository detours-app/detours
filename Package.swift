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
        .library(name: "QualificationSupport", targets: ["QualificationSupport"]),
        .executable(name: "detours-qualification-guard", targets: ["detours-qualification-guard"]),
        .executable(
            name: "detours-qualification-smb-mounter",
            targets: ["detours-qualification-smb-mounter"]
        ),
    ],
    targets: [
        .target(
            name: "SevenZip", path: "SevenZip",
            exclude: ["README.md", "License.txt", "copying.txt", "unRarLicense.txt"],
            cSettings: [.define("Z7_DEFLATE_EXTRACT_ONLY"), .define("Z7_BZIP2_EXTRACT_ONLY")],
            cxxSettings: [.define("Z7_DEFLATE_EXTRACT_ONLY"), .define("Z7_BZIP2_EXTRACT_ONLY")]
        ),
        .target(name: "ArchiveStreamBridge", dependencies: ["SevenZip"], path: "ArchiveStreamBridge"),
        .target(name: "FilesystemPrimitives", path: "FilesystemPrimitives"),
        .target(
            name: "RemoteOperationSupport",
            dependencies: ["FilesystemPrimitives"],
            path: "RemoteOperationSupport"
        ),
        .target(
            name: "DetoursProcess",
            dependencies: ["ArchiveStreamBridge"],
            path: "Shared",
            linkerSettings: [
                .linkedLibrary("util", .when(platforms: [.linux]))
            ]
        ),
        .target(
            name: "QualificationSupport",
            path: "QualificationSupport"
        ),
        .executableTarget(
            name: "detours-qualification-guard",
            dependencies: ["QualificationSupport"],
            path: "QualificationGuard"
        ),
        .executableTarget(
            name: "detours-qualification-smb-mounter",
            path: "QualificationSMBMounter"
        ),
        .executableTarget(
            name: "Detours",
            dependencies: ["DetoursProcess", "RemoteOperationSupport"],
            path: "src",
            swiftSettings: detoursSwiftSettings
        ),
        .executableTarget(
            name: "detours-server",
            dependencies: ["DetoursProcess", "RemoteOperationSupport"],
            path: "Server"
        ),
        .testTarget(
            name: "DetoursTests",
            dependencies: ["Detours", "DetoursProcess", "RemoteOperationSupport", "QualificationSupport", "detours-server"],
            path: "Tests",
            exclude: ["TEST_LOG.md", "UITests", "DetoursProcessTests"]
        ),
        .testTarget(
            name: "DetoursProcessTests",
            dependencies: ["DetoursProcess"],
            path: "Tests/DetoursProcessTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
