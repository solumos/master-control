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
        .library(name: "MCActions", targets: ["MCActions"]),
        .executable(name: "mc-spike", targets: ["MCSpike"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
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
        .executableTarget(
            name: "MCSpike",
            dependencies: [
                "MCCore",
                "MCAudio",
                "MCSTT",
                "MCRouter",
                "MCActions",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
