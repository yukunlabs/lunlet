// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-10, AC-10.02, AC-10.04; US-11, AC-11.05.
// Refs: US-01, AC-01.01, AC-01.02, AC-01.04, AC-01.05.
// Refs: US-03, AC-03.04; US-05, AC-05.03; US-12, AC-12.02, AC-12.04.
// Refs: US-05, AC-05.04, AC-05.05.
// Refs: US-02, AC-02.04, AC-02.07.
// Refs: US-14, AC-14.01, AC-14.03.
// Refs: US-04, AC-04.01, AC-04.03, AC-04.04, AC-04.05, AC-04.06.
// Refs: US-33, AC-33.01, AC-33.04; US-19, AC-19.01.
// Refs: US-35, AC-35.01, AC-35.02, AC-35.04; US-29, AC-29.03.
import PackageDescription

let package = Package(
    name: "Lunlet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lunlet", targets: ["LunletApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
        // Update checks and installation for configured release builds; its license ships in the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "LunletCore"),
        // Keychain access shared by every channel; kept out of Core so Core stays Foundation-only.
        .target(name: "LunletSecureStorage", dependencies: ["LunletCore"]),
        .target(name: "LunletFeishu", dependencies: ["LunletCore", "LunletSecureStorage",
                                                     .product(name: "SwiftProtobuf", package: "swift-protobuf")],
                exclude: ["Protocol"], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "LunletCodex", dependencies: ["LunletCore"]),
        .target(name: "LunletClaude", dependencies: ["LunletCore"]),
        .target(name: "LunletMessaging", dependencies: ["LunletCore", "LunletSecureStorage"]),
        .target(name: "LunletDesktop", dependencies: ["LunletCore", "LunletSecureStorage", "LunletFeishu",
                                                      "LunletCodex", "LunletClaude", "LunletMessaging",
                                                      .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "LunletApp", dependencies: ["LunletDesktop", "LunletCore"]),
        .testTarget(name: "LunletCoreTests", dependencies: ["LunletCore"]),
        .testTarget(name: "LunletSecureStorageTests", dependencies: ["LunletSecureStorage", "LunletCore"]),
        .testTarget(name: "LunletMessagingTests", dependencies: ["LunletMessaging", "LunletSecureStorage", "LunletCore"]),
        .testTarget(name: "LunletFeishuTests", dependencies: ["LunletFeishu", "LunletSecureStorage", "LunletCore",
                                                              .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .testTarget(name: "LunletDesktopTests", dependencies: ["LunletDesktop"]),
        .testTarget(name: "LunletCodexTests", dependencies: ["LunletCodex"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LunletClaudeTests", dependencies: ["LunletClaude", "LunletCore"]),
    ]
)
