// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppShelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AppShelf", targets: ["AppShelf"])
    ],
    targets: [
        .executableTarget(
            name: "AppShelf",
            path: "Sources/AppShelf"
        )
    ],
    swiftLanguageModes: [.v5]
)
