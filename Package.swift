// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AppleiMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AppMonitorCore", targets: ["AppMonitorCore"]),
        .executable(name: "AppleiMonitor", targets: ["AppMonitor"]),
        .executable(name: "AppleiMonitorAskpass", targets: ["AppleiMonitorAskpass"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3"
        ),
        .target(
            name: "AppMonitorCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "AppMonitor",
            dependencies: ["AppMonitorCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AppleiMonitorAskpass",
            path: "Sources/AppMonitorAskpass"
        ),
        .testTarget(
            name: "AppMonitorCoreTests",
            dependencies: ["AppMonitorCore"]
        )
    ]
)
