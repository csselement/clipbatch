// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatchClip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BatchClip", targets: ["BatchClip"])
    ],
    targets: [
        .executableTarget(
            name: "BatchClip",
            path: "Sources/BatchClip"
        ),
        .testTarget(
            name: "BatchClipTests",
            dependencies: ["BatchClip"],
            path: "Tests/BatchClipTests"
        )
    ]
)
