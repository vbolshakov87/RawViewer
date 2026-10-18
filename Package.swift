// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RawViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RawViewer", path: "Sources/RawViewer")
    ]
)
