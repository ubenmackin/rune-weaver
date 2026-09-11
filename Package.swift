// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuneWeaver",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "rune-weaver", targets: ["RuneWeaverCLI"]),
        .library(name: "RuneWeaverCore", targets: ["RuneWeaverCore"]),
        .library(name: "RuneWeaverLLM", targets: ["RuneWeaverLLM"]),
        .library(name: "RuneWeaverTools", targets: ["RuneWeaverTools"]),
        .library(name: "RuneWeaverVoice", targets: ["RuneWeaverVoice"]),
        .library(name: "RuneWeaverClient", targets: ["RuneWeaverClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.4"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.3.0")
    ],
    targets: [
        .target(
            name: "RuneWeaverCore",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "RuneWeaverLLM",
            dependencies: [
                "RuneWeaverCore",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "RuneWeaverTools",
            dependencies: [
                "RuneWeaverCore",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "RuneWeaverVoice",
            dependencies: [
                "RuneWeaverCore",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "RuneWeaverClient",
            dependencies: [
                "RuneWeaverCore",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "RuneWeaverCLI",
            dependencies: [
                "RuneWeaverCore",
                "RuneWeaverLLM",
                "RuneWeaverTools",
                "RuneWeaverVoice",
                "RuneWeaverClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "RuneWeaverCoreTests",
            dependencies: ["RuneWeaverCore"]
        ),
        .testTarget(
            name: "RuneWeaverLLMTests",
            dependencies: ["RuneWeaverCore", "RuneWeaverLLM"]
        ),
        .testTarget(
            name: "RuneWeaverToolsTests",
            dependencies: ["RuneWeaverCore", "RuneWeaverTools"]
        ),
        .testTarget(
            name: "RuneWeaverVoiceTests",
            dependencies: ["RuneWeaverCore", "RuneWeaverVoice"]
        ),
        .testTarget(
            name: "RuneWeaverClientTests",
            dependencies: ["RuneWeaverCore", "RuneWeaverClient"]
        )
    ]
)
