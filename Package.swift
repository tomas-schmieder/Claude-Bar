// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ClaudeBarCore", targets: ["ClaudeBarCore"]),
        .executable(name: "ClaudeBar", targets: ["ClaudeBar"]),
        .executable(name: "ClaudeBarDebug", targets: ["ClaudeBarDebug"]),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.4.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.13.2"),
    ],
    targets: [
        .target(
            name: "ClaudeBarCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SweetCookieKit", package: "SweetCookieKit"),
            ],
            path: "Sources/ClaudeBarCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "ClaudeBar",
            dependencies: ["ClaudeBarCore"],
            path: "Sources/ClaudeBar"),
        .executableTarget(
            name: "ClaudeBarDebug",
            dependencies: ["ClaudeBarCore"],
            path: "Sources/ClaudeBarDebug"),
    ])
