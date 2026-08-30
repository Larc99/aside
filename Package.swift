// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aside",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Aside",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .copy("Resources/Fonts")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AsideTests",
            dependencies: [
                .target(name: "Aside"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
