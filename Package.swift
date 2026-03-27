// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-ghostty",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Ghostty", targets: ["Ghostty"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework.zip"
        ),
        .target(
            name: "GhosttyVT"
        ),
        .target(
            name: "Ghostty",
            dependencies: [
                .target(name: "GhosttyKit"),
                .target(name: "GhosttyVT"),
            ],
            resources: [
                .copy("Resources/Themes"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "GhosttyTests",
            dependencies: [
                .target(name: "Ghostty"),
            ]
        ),
    ]
)
