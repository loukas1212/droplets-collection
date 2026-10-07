// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Disks",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Disks", type: .dynamic, targets: ["Disks"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.6.0")
    ],
    targets: [
        .target(
            name: "Disks",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "DisksHarness",
            dependencies: [
                "Disks",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)