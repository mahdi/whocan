// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "whocan",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "whocan", path: "Sources/whocan")
    ]
)
