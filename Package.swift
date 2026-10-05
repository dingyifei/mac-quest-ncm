// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacQuestNCM",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "mqncm", targets: ["mqncm"]),
        .executable(name: "MacQuestNCMApp", targets: ["MacQuestNCMApp"]),
        .library(name: "MQNCMCore", targets: ["MQNCMCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MQNCMCore",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "mqncm",
            dependencies: [
                "MQNCMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "MacQuestNCMApp",
            dependencies: ["MQNCMCore"]
        ),
        .testTarget(name: "MQNCMCoreTests", dependencies: ["MQNCMCore"]),
    ],
    swiftLanguageModes: [.v5]
)
