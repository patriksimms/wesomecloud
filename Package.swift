// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WesomeCloud",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WesomeCloudShared", targets: ["WesomeCloudShared"]),
        .library(name: "OwnCloudKit", targets: ["OwnCloudKit"]),
        .library(name: "SyncStore", targets: ["SyncStore"]),
        .library(name: "WesomeFileProviderCore", targets: ["WesomeFileProviderCore"]),
        .library(name: "WesomeCloudAppCore", targets: ["WesomeCloudAppCore"]),
        .library(name: "WesomeCloudMacApp", targets: ["WesomeCloudMacApp"]),
        .library(name: "WesomeFileProviderExtension", targets: ["WesomeFileProviderExtension"]),
        .executable(name: "wesomecloud", targets: ["WesomeCloudApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
    ],
    targets: [
        .target(name: "WesomeCloudShared"),
        .target(name: "OwnCloudKit", dependencies: ["WesomeCloudShared"]),
        .target(
            name: "SyncStore",
            dependencies: ["WesomeCloudShared"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "WesomeFileProviderCore",
            dependencies: ["WesomeCloudShared", "OwnCloudKit", "SyncStore"]
        ),
        .target(
            name: "WesomeCloudAppCore",
            dependencies: ["WesomeCloudShared", "OwnCloudKit", "SyncStore", "WesomeFileProviderCore"]
        ),
        .target(
            name: "WesomeCloudMacApp",
            dependencies: [
                "WesomeCloudAppCore",
                "WesomeCloudShared",
                "SyncStore",
                "WesomeFileProviderCore",
                "WesomeFileProviderExtension",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "WesomeCloudApp",
            dependencies: ["WesomeCloudAppCore", "WesomeCloudMacApp"]
        ),
        .target(
            name: "WesomeFileProviderExtension",
            dependencies: ["WesomeCloudShared", "OwnCloudKit", "SyncStore", "WesomeFileProviderCore", "WesomeCloudAppCore"]
        ),
        .testTarget(name: "WesomeCloudSharedTests", dependencies: ["WesomeCloudShared"]),
        .testTarget(name: "OwnCloudKitTests", dependencies: ["OwnCloudKit"]),
        .testTarget(name: "SyncStoreTests", dependencies: ["SyncStore"]),
        .testTarget(name: "WesomeCloudAppCoreTests", dependencies: ["WesomeCloudAppCore", "SyncStore"]),
        .testTarget(name: "WesomeCloudMacAppTests", dependencies: ["WesomeCloudMacApp", "SyncStore", "WesomeFileProviderCore", "WesomeFileProviderExtension"]),
        .testTarget(name: "WesomeFileProviderExtensionTests", dependencies: ["WesomeFileProviderExtension", "SyncStore"]),
        .testTarget(
            name: "WesomeFileProviderCoreTests",
            dependencies: ["WesomeFileProviderCore", "OwnCloudKit", "SyncStore"]
        ),
    ]
)
