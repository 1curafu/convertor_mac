// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Convertor",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Convertor",
            path: "Sources/Convertor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ConvertorTests",
            dependencies: ["Convertor"],
            path: "Tests/ConvertorTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
