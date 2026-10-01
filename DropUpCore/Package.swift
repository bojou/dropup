// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropUpCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DropUpCore", targets: ["DropUpCore"]),
    ],
    targets: [
        .target(name: "DropUpCore"),
        .testTarget(name: "DropUpCoreTests", dependencies: ["DropUpCore"]),
    ]
)
