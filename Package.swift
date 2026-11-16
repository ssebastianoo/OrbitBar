// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "OrbitBar",
            dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources/OrbitBar",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "OrbitBarTests",
            dependencies: ["OrbitBar"],
            path: "Tests/OrbitBarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
