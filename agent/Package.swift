// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CopyMemoryAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "copy-memory-agent", targets: ["ClipAgent"]),
    ],
    targets: [
        .target(name: "ClipCore"),
        .executableTarget(name: "ClipAgent", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
    ]
)
