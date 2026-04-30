// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RimeoAgent",
    platforms: [.macOS(.v11)],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "RimeoAgent",
            path: "Sources/RimeoAgentMac",
            cSettings: [
                .define("SQLITE_HAS_CODEC", to: "1"),
            ]
        ),
        .executableTarget(
            name: "RekordboxDBHelper",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            path: "Sources/RekordboxDBHelper",
            cSettings: [
                .define("SQLITE_HAS_CODEC", to: "1"),
            ]
        ),
        .testTarget(
            name: "RimeoAgentTests",
            dependencies: ["RimeoAgent"],
            path: "Tests/RimeoAgentTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
