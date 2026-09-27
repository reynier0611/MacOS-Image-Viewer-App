// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ImageViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ImageViewer",
            path: "Sources/ImageViewer"
        )
    ]
)
