// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BasicTerminal",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "BasicTerminal",
            dependencies: [
                .product(name: "Ghostty", package: "swift-ghostty"),
            ]
        ),
    ]
)
