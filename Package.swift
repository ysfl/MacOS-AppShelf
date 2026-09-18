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
        // Pure, UI-free logic: search ranking, ordering math, grid geometry, persistence
        // codecs. Everything here is covered by `AppShelfCoreTests`.
        .target(
            name: "AppShelfCore",
            path: "Sources/AppShelfCore"
        ),
        .executableTarget(
            name: "AppShelf",
            dependencies: ["AppShelfCore"],
            path: "Sources/AppShelf",
            // Carbon provides the global hotkey API used by the Spotlight-style panel.
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "AppShelfCoreTests",
            dependencies: ["AppShelfCore"],
            path: "Tests/AppShelfCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
