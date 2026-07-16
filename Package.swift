// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "VoxLocal",
    defaultLocalization: "ru",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "VoxLocalCore",
            path: "Sources/VoxLocalCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "VoxLocal",
            dependencies: ["VoxLocalCore"],
            path: "Sources/VoxLocal"
        ),
        .testTarget(
            name: "VoxLocalTests",
            dependencies: ["VoxLocalCore"],
            path: "Tests/VoxLocalTests"
        ),
    ]
)
