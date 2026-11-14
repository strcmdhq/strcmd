// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StarCommand",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StarCommand",
            path: "Sources/StarCommand"
        ),
        .testTarget(
            name: "StarCommandTests",
            dependencies: ["StarCommand"],
            path: "Tests/StarCommandTests"
        ),
    ]
)
