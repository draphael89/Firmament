// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "FirmamentKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "FirmamentKit", targets: ["FirmamentKit"]),
        .executable(name: "firmament", targets: ["firmament"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "FirmamentKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "firmament",
            dependencies: ["FirmamentKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FirmamentKitTests",
            dependencies: ["FirmamentKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
