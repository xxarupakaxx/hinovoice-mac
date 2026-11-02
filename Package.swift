// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HinoVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HinoVoice",
            path: "Sources/HinoVoice",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
