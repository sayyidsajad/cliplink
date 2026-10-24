// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipLink",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClipLinkCore", path: "Sources/ClipLinkCore"),
        .executableTarget(
            name: "ClipLink",
            dependencies: ["ClipLinkCore"],
            path: "Sources/ClipLink"
        ),
        .executableTarget(
            name: "ClipLinkCLI",
            dependencies: ["ClipLinkCore"],
            path: "Sources/ClipLinkCLI"
        ),
    ]
)
