// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "IrisArchitectureRules",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/perrystreetsoftware/Harmonize.git", exact: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "601.0.1"),
        // Already pinned transitively; preflight YAML so Harmonize cannot trap on a bad config.
        .package(url: "https://github.com/jpsim/Yams.git", exact: "5.4.0"),
    ],
    targets: [
        .testTarget(
            name: "ArchitectureRulesTests",
            dependencies: [
                .product(name: "Harmonize", package: "harmonize"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "Yams", package: "yams"),
            ])
    ],
    swiftLanguageModes: [.v6]
)
