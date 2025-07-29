// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "SocketIO",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(name: "SocketIO", targets: ["SocketIO"])
    ],
    dependencies: [
        .package(url: "https://github.com/theleftbit/Starscream.git", branch: "android"),
    ],
    targets: [
        .target(name: "SocketIO", dependencies: ["Starscream"]),
        .testTarget(name: "TestSocketIO", dependencies: ["SocketIO"]),
    ],
    swiftLanguageModes: [.v6]
)
