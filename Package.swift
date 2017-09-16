import PackageDescription

let deps: [Package.Dependency]

#if !os(Linux)
deps = [.Package(url: "https://github.com/nuclearace/Starscream", majorVersion: 8)]
#else
deps = [.Package(url: "https://github.com/vapor/engine", majorVersion: 2)]
#endif

let package = Package(
    name: "SocketIO",
    dependencies: deps,
    exclude: ["Source/Starscream"]
)
