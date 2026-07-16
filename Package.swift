// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncedLyricsKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SyncedLyricsKit", targets: ["SyncedLyricsKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/b5i/YouTubeKit", from: "2.8.0")
    ],
    targets: [
        .target(name: "SyncedLyricsKit", dependencies: ["YouTubeKit"]),
        .testTarget(name: "SyncedLyricsKitTests", dependencies: ["SyncedLyricsKit"])
    ]
)
