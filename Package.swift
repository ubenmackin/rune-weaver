// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RuneWeaver",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "rune-weaver", targets: ["RuneWeaverCLI"]),
        .executable(name: "RuneWeaverApp", targets: ["RuneWeaverApp"]),
        .library(name: "RuneWeaverCore", targets: ["RuneWeaverCore"]),
        .library(name: "RuneWeaverLLM", targets: ["RuneWeaverLLM"]),
        .library(name: "RuneWeaverTools", targets: ["RuneWeaverTools"]),
        .library(name: "RuneWeaverVoice", targets: ["RuneWeaverVoice"]),
        .library(name: "RuneWeaverClient", targets: ["RuneWeaverClient"]),
        .library(name: "RuneWeaverServer", targets: ["RuneWeaverServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.4"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.3.0"),
        .package(url: "https://github.com/mattt/bestline-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/johnsundell/ink.git", from: "0.6.0")
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
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Ink", package: "ink")
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
        .target(
            name: "RuneWeaverServer",
            dependencies: [
                "RuneWeaverCore",
                "RuneWeaverTools",
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .executableTarget(
            name: "RuneWeaverCLI",
            dependencies: [
                "RuneWeaverCore",
                "RuneWeaverLLM",
                "RuneWeaverTools",
                "RuneWeaverServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Bestline", package: "bestline-swift")
            ]
        ),
        .executableTarget(
            name: "RuneWeaverApp",
            dependencies: [
                "RuneWeaverCore",
                "RuneWeaverLLM",
                "RuneWeaverTools",
                "RuneWeaverServer",
                .product(name: "Vapor", package: "vapor"),
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
            dependencies: ["RuneWeaverCore", "RuneWeaverTools", "RuneWeaverLLM"]
        ),
        .testTarget(
            name: "RuneWeaverVoiceTests",
            dependencies: ["RuneWeaverCore", "RuneWeaverVoice"]
        ),
        .testTarget(
            name: "RuneWeaverClientTests",
            dependencies: ["RuneWeaverCore", "RuneWeaverClient"]
        ),
        .testTarget(
            name: "RuneWeaverCLITests",
            dependencies: ["RuneWeaverCLI"]
        ),
        .testTarget(
            name: "RuneWeaverServerTests",
            dependencies: ["RuneWeaverServer", "RuneWeaverCore"]
        ),
        .testTarget(
            name: "RuneWeaverAppTests",
            dependencies: ["RuneWeaverApp", "RuneWeaverCore", "RuneWeaverServer"]
        )
    ],
    swiftLanguageModes: [.v6]
)
