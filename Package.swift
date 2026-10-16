// swift-tools-version: 5.9
import PackageDescription

// The domain and AI fallback are testable without AppKit or an installed model.
var products: [Product] = [.library(name: "FastCleanupCore", targets: ["FastCleanupCore"])]
var targets: [Target] = [
    .target(name: "FastCleanupCore"),
    .target(name: "FastCleanupAI", dependencies: ["FastCleanupCore"]),
    .testTarget(name: "FastCleanupCoreTests", dependencies: ["FastCleanupCore"]),
    .testTarget(name: "FastCleanupAITests", dependencies: ["FastCleanupAI", "FastCleanupCore"]),
]
#if os(macOS)
products.append(.executable(name: "FastCleanup", targets: ["FastCleanup"]))
targets.append(.executableTarget(name: "FastCleanup", dependencies: ["FastCleanupCore", "FastCleanupAI"]))
#endif
let package = Package(name: "FastCleanup", platforms: [.macOS(.v14)], products: products, targets: targets)
