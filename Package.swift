// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIStatus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIStatus",
            path: "Sources/AIStatus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
