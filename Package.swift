// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BrowserPOC",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "BrowserPOC",
            path: "Sources/BrowserPOC",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
