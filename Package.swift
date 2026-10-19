// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Convertor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Convertor",
            path: "Sources/Convertor"
        )
    ]
)
