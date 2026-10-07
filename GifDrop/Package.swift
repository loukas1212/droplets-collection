// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GifDrop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GifDrop", type: .dynamic, targets: ["GifDrop"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.20.0")
    ],
    targets: [
        .target(
            name: "GifDrop",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "GifDropHarness",
            dependencies: [
                "GifDrop",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)