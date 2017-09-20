// swift-tools-version:4.0

import PackageDescription

let package = Package(
    name: "SocketIO",
    dependencies: [
        .package(url: "https://github.com/nuclearace/Starscream", from: "8.0.0"),
    ],
    targets: [
        .target(name: "SocketIO", exclude: ["Sources/Starscream"])
    ]
)
