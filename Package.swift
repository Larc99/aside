// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickyDeck",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "StickyDeck",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .copy("Resources/Fonts")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StickyDeckTests",
            dependencies: [
                .target(name: "StickyDeck"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
