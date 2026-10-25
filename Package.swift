// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Iris",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IrisCore"),
        .target(name: "IrisProviders", dependencies: ["IrisCore"]),
        .executableTarget(name: "IrisMacOS", dependencies: ["IrisCore", "IrisProviders"]),
        .executableTarget(name: "MockASRServer"),
        .testTarget(name: "IrisCoreTests", dependencies: ["IrisCore", "IrisProviders"]),
        .testTarget(name: "IrisMacOSTests", dependencies: ["IrisCore", "IrisProviders", "IrisMacOS"]),
    ],
    swiftLanguageModes: [.v6]
)
