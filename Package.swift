// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "StickyAI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "StickyAICore", targets: ["StickyAICore"]),
        .executable(name: "StickyAI", targets: ["StickyAIApp"])
    ],
    targets: [
        .target(
            name: "StickyAICore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "StickyAIApp",
            dependencies: ["StickyAICore"]
        ),
        .testTarget(
            name: "StickyAITests",
            dependencies: ["StickyAICore"]
        )
    ]
)

