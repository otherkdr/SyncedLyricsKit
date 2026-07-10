// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterLyricsKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BetterLyricsKit", targets: ["BetterLyricsKit"])
    ],
    targets: [
        .target(name: "BetterLyricsKit"),
        .testTarget(name: "BetterLyricsKitTests", dependencies: ["BetterLyricsKit"])
    ]
)
