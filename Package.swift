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
            // Deliberately not a SwiftPM resource: that would generate a
            // Bundle.module accessor with this machine's .build path baked in,
            // which is what crashed 0.8.0 on every other Mac. bundle.sh copies
            // the font into Contents/Resources itself.
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
