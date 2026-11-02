// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "clipb",
    platforms: [.macOS(.v13)],
    targets: [
        // whisper.cpp (MIT), prebuilt by ggml-org: on-device speech to text for
        // voice copy (SPEC §2.13). Bundled into Contents/Frameworks by the Makefile.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .executableTarget(
            name: "clipb",
            dependencies: ["whisper"],
            path: "Sources/clipb",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "clipbTests",
            dependencies: ["clipb"],
            path: "Tests/clipbTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
