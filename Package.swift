// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
