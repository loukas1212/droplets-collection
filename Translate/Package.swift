// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Translate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Translate", type: .dynamic, targets: ["Translate"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.20.1")
    ],
    targets: [
        .target(
            name: "Translate",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "TranslateHarness",
            dependencies: [
                "Translate",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)
