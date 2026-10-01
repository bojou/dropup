// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropUpCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DropUpCore", targets: ["DropUpCore"]),
        .library(name: "DropUpTransport", targets: ["DropUpTransport"]),
    ],
    dependencies: [
        // SSH/SFTP client in pure Swift. Pinned exactly: SSH code is security-sensitive,
        // so upgrades should be deliberate.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
        // The same SwiftNIO SSH fork Citadel 0.12.0 uses, for host key types.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        // All app logic. No third-party dependencies, fully unit tested.
        .target(name: "DropUpCore"),
        // Real network transports: Network.framework byte streams for FTP, Citadel for SFTP.
        // Swift 5 mode because Citadel and NIOSSH predate strict concurrency checking.
        .target(
            name: "DropUpTransport",
            dependencies: [
                "DropUpCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DropUpCoreTests", dependencies: ["DropUpCore"]),
        // End-to-end tests against real FTP and SFTP servers. Skipped unless DROPUP_IT_* variables are set
        // (see scripts/test-servers.py and the CI workflow).
        .testTarget(
            name: "DropUpIntegrationTests",
            dependencies: ["DropUpCore", "DropUpTransport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
