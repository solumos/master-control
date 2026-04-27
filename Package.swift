// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MasterControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MCCore", targets: ["MCCore"]),
        .library(name: "MCAudio", targets: ["MCAudio"]),
        .library(name: "MCSTT", targets: ["MCSTT"]),
        .library(name: "MCInput", targets: ["MCInput"]),
        .library(name: "MCRouter", targets: ["MCRouter"]),
        .library(name: "MCMlx", targets: ["MCMlx"]),
        .library(name: "MCCloud", targets: ["MCCloud"]),
        .library(name: "MCActions", targets: ["MCActions"]),
        .executable(name: "mc-spike", targets: ["MCSpike"]),
        .executable(name: "MasterControl", targets: ["MCApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.1"),
    ],
    targets: [
        .target(name: "MCCore"),
        .target(
            name: "MCAudio",
            dependencies: [
                "MCCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(
            name: "MCSTT",
            dependencies: [
                "MCCore",
                "MCAudio",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(
            name: "MCInput",
            dependencies: ["MCCore"]
        ),
        .target(
            name: "MCRouter",
            dependencies: ["MCCore"]
        ),
        .target(
            name: "MCActions",
            dependencies: ["MCCore"]
        ),
        .target(
            name: "MCCloud",
            dependencies: ["MCCore"]
        ),
        .target(
            name: "MCMlx",
            dependencies: [
                "MCCore",
                "MCRouter",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .executableTarget(
            name: "MCSpike",
            dependencies: [
                "MCCore",
                "MCAudio",
                "MCSTT",
                "MCRouter",
                "MCMlx",
                "MCActions",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "MCApp",
            dependencies: [
                "MCCore",
                "MCAudio",
                "MCSTT",
                "MCRouter",
                "MCCloud",
                "MCActions",
                "MCInput",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
