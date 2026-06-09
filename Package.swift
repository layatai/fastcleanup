// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FastCleanup",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FastCleanup", targets: ["FastCleanup"])],
    targets: [
        .executableTarget(name: "FastCleanup", path: "Sources/FastCleanup")
    ]
)
