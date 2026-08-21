// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "clipb",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "clipb",
            path: "Sources/clipb",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "clipbTests",
            dependencies: ["clipb"],
            path: "Tests/clipbTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
