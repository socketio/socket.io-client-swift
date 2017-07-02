import PackageDescription

let package = Package(
    name: "SocketIO",
    dependencies: [
        .Package(url: "https://github.com/daltoniam/zlib-spm.git", majorVersion: 1),
        .Package(url: "https://github.com/daltoniam/common-crypto-spm.git", majorVersion: 1)
    ]
)
