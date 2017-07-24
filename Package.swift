import PackageDescription

let package = Package(
    name: "SocketIO",
    dependencies: [
        .Package(url: "https://github.com/nuclearace/Starscream", majorVersion: 8),
    ],
    exclude: ["Source/Starscream"]
)
