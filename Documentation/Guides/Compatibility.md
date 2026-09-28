# Compatibility

[Documentation index](../README.md) · [Getting started](GettingStarted.md)

The current line of this fork supports **Socket.IO 4.x servers** using
**Engine.IO protocol 4** only.

| Socket.IO server | Support in this fork |
| --- | --- |
| 2.x and older | Not supported; Engine.IO 3 was removed |
| 3.x | Not supported or tested |
| 4.x | Supported, no version selector required |

Socket.IO 3 and 4 share the modern wire protocol, so the handshake cannot prove
a server's major version. This is a supported-version boundary, not a claim that
the client can identify and reject every 3.x server.

```swift
let manager = SocketManager(
    socketURL: URL(string: "http://localhost:8080/")!,
    config: [.log(false)]
)
```

Remove `.version(.two)`, `.version(.three)` and dictionary `"version"` entries.
There is no replacement `.four` option. An explicit dictionary version is a
configuration error. User-supplied `EIO` query values cannot re-enable protocol 3.
Connection State Recovery requires Socket.IO 4.6+ and server-side configuration.

## Swift and deployment targets

Use the Swift 6.4 toolchain, or newer, with Swift 6 language mode. Xcode 27 is used
by CI. Minimum deployment targets are iOS 15, macOS 12, tvOS 15 and watchOS 9.
[Package.swift](../../Package.swift) is the source of truth for the build baseline.

The client remains serial-queue-owned, not actor-based. Consult
[the migration guide](../SocketIO4Swift6Migration.md) for removed APIs and the
async authentication/acknowledgement concurrency contract.

Compatibility tables for older upstream Swift client releases do not describe
this fork's current API or supported server range. Swift Package Manager is the
only supported installation method.
