// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BrowserPOC",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "BrowserPOC",
            dependencies: ["llama"],
            path: "Sources/BrowserPOC",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // llama.cpp's official build, with Metal. Runs the on-device embedding and reranking models.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12121/llama-b12121-xcframework.zip",
            checksum: "00bc6fec00beba802a3912a6afb81e1678da5248a6a92548a9ce66724a3e7638"
        ),
    ]
)
