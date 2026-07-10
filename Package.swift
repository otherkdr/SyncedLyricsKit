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
    targets: [
        .target(name: "SyncedLyricsKit"),
        .testTarget(name: "SyncedLyricsKitTests", dependencies: ["SyncedLyricsKit"])
    ]
)
