// swift-tools-version:5.10
import PackageDescription

// Tools version 5.10 builds every target in the Swift 5 language mode.
let package = Package(
    name: "SnugBar",
    platforms: [
        // `.v27` needs tools version 6.4; the string form works with 5.10.
        .macOS("27.0"),
    ],
    products: [
        .library(name: "SnugBarCore", targets: ["SnugBarCore"]),
        .library(name: "SnugBarEngine", targets: ["SnugBarEngine"]),
        .executable(name: "SnugBar", targets: ["SnugBar"]),
    ],
    targets: [
        .target(
            name: "SnugBarCore"
        ),
        .target(
            name: "SnugBarEngine",
            dependencies: ["SnugBarCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "SnugBar",
            dependencies: ["SnugBarCore", "SnugBarEngine"]
        ),
        .testTarget(
            name: "SnugBarCoreTests",
            dependencies: ["SnugBarCore"]
        ),
        .testTarget(
            name: "SnugBarEngineTests",
            dependencies: ["SnugBarEngine", "SnugBarCore"]
        ),
    ]
)
