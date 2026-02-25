// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenCAN",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.7.0"),
        .package(url: "https://github.com/Lakr233/MarkdownView", from: "3.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "OpenCAN",
            dependencies: [
                "Citadel",
                .product(name: "MarkdownView", package: "MarkdownView"),
            ],
            path: "Sources",
            resources: [
                .copy("../Resources/id_rsa_zd"),
            ]
        ),
    ]
)
