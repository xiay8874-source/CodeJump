// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeJump",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodeJumpCore", targets: ["CodeJumpCore"]),
        .executable(name: "CodeJump", targets: ["CodeJump"]),
        .executable(name: "codejump-cli", targets: ["codejump-cli"])
    ],
    targets: [
        .target(name: "CodeJumpCore"),
        .executableTarget(name: "CodeJump", dependencies: ["CodeJumpCore"]),
        .executableTarget(name: "codejump-cli", dependencies: ["CodeJumpCore"]),
        .testTarget(name: "CodeJumpCoreTests", dependencies: ["CodeJumpCore"])
    ]
)
