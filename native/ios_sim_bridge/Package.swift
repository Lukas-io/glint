// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "glint-iossim",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "glint-iossim",
            path: "Sources/glint-iossim",
            linkerSettings: [
                // CoreSimulator.framework is a private framework shipped with
                // Xcode (not in the macOS SDK), so we dlopen it at runtime
                // rather than link at build time. IOKit (for IOHIDEvent) is
                // public-but-private-detail; same pattern.
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
