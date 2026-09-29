// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ImageViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ImageViewer",
            path: "Sources/ImageViewer"
        ),
        // Run with ./test.sh (it finds Swift Testing when only the Command Line Tools are installed).
        .testTarget(
            name: "ImageViewerTests",
            dependencies: ["ImageViewer"],
            path: "Tests/ImageViewerTests"
        ),
    ]
)
