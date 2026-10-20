// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocVision",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DocVision", targets: ["DocVision"])
    ],
    targets: [
        .executableTarget(name: "DocVision"),
        .testTarget(name: "DocVisionTests", dependencies: ["DocVision"])
    ]
)
