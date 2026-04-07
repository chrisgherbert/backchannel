// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "youtube-live-converter",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(
            url: "https://github.com/HaishinKit/HaishinKit.swift.git",
            revision: "6ff1395755f89975b53e511f54ae78c79ee8576e"
        )
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat",
            providers: [
                .brew(["ffmpeg"])
            ]
        ),
        .executableTarget(
            name: "youtube-live-converter",
            dependencies: [
                "CFFmpeg",
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift")
            ]
        ),
        .testTarget(
            name: "youtube-live-converterTests",
            dependencies: ["youtube-live-converter"]
        ),
    ]
)
