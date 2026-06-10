// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Gatecaster",
    platforms: [.macOS(.v13)],
    targets: [
        // Gesture-synthesis target (original implementation).
        .target(
            name: "GestureKit",
            path: "Sources/GestureKit"
        ),
        .executableTarget(
            name: "Gatecaster",
            dependencies: ["GestureKit"],
            path: "Sources/Gatecaster",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
