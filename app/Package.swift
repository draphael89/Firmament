// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Firmament",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FirmamentCore", targets: ["FirmamentCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "FirmamentCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "FirmamentCoreTests",
            dependencies: ["FirmamentCore"]
        ),
    ]
)
