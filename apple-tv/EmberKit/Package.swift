// swift-tools-version:5.9
// EmberKit: Ember's Jellyfin and Seerr clients for Apple platforms.
// Foundation only, so the tests also run on Linux (`swift test`).
import PackageDescription

let package = Package(
    name: "EmberKit",
    platforms: [.tvOS(.v17), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EmberKit", targets: ["EmberKit"]),
    ],
    targets: [
        .target(name: "EmberKit"),
        .testTarget(name: "EmberKitTests", dependencies: ["EmberKit"]),
    ]
)
