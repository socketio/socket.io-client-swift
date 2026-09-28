# Getting started

[Documentation index](../README.md) · [Project overview](../../README.md)

Use the main queue for the examples on this page, which use the default `handleQueue`. Keep both your application wrapper and its manager alive. These are application snippets, not separate top-level scripts.

## At a glance

- Socket.IO 4.x / Engine.IO 4
- HTTP long-polling and WebSocket
- Automatic polling → WebSocket upgrades
- Native URLSessionWebSocketTask
- Text and binary events
- Namespaces
- Acknowledgements, timeouts and retries
- async/await acknowledgement APIs
- Automatic reconnection with Socket.IO-compatible backoff semantics
- Dynamic authentication providers
- Connection State Recovery with compatible Socket.IO 4.6+ servers
- Volatile events
- TLS system trust, certificate pinning and private trust anchors
- Swift 6 concurrency checking
- No third-party Swift dependencies

This library implements the Socket.IO protocol. It is not a generic WebSocket client.

## Requirements

| Minimum | |
| --- | --- |
| Swift toolchain | Swift 6.4 |
| Swift language mode | Swift 6 |
| Xcode | Xcode 27 |
| iOS | 15 |
| macOS | 12 |
| tvOS | 15 |
| watchOS | 9 |
| Socket.IO server | 4.x |
| Engine.IO protocol | 4 |

Socket.IO 2.x and earlier protocol modes are no longer supported.

Socket.IO 3.x shares much of the modern wire protocol, but it is outside the supported and tested server range of this client.

## Transport support

| Transport | Support |
| --- | --- |
| HTTP long-polling | ✅ |
| WebSocket | ✅ |
| Polling → WebSocket upgrade | ✅ |
| WebSocket-only | ✅ |
| WebTransport | ❌ |

## Installation

Swift Package Manager is the only supported installation method.

In Xcode, choose:

**File → Add Package Dependencies**

and enter:

```text
https://github.com/kaeferfreund/socket.io-client-swift.git
```

Use version **17.1.0** or later within the 17.x series. In Xcode, select
**Up to Next Major Version** from **17.1.0** and add the **SocketIO** product
to your app target.

A version requirement selects a published release, not the development branch
you are viewing. Select a reviewed branch or commit explicitly to evaluate
unreleased changes. See the [17.1.0 release notes](../Release17.1.0.md) and
[why this fork exists](WhyThisFork.md).

For a Package.swift:

```swift
dependencies: [
    .package(
        url: "https://github.com/kaeferfreund/socket.io-client-swift.git",
        from: "17.1.0"
    )
]
```

Then add the library to your target:

```swift
.product(
    name: "SocketIO",
    package: "socket.io-client-swift"
)
```

Import the package with:

```swift
import SocketIO
```

## Quick start

Keep the `SocketManager` alive for as long as you use its sockets. The wrapper
uses `@MainActor` because the default `handleQueue` is the main queue. This does
not make the underlying manager or socket `Sendable`, and a custom queue needs
its own consistent ownership strategy.

```swift
import Foundation
import SocketIO

@MainActor
final class RealtimeClient {
    private let manager: SocketManager
    private let socket: SocketIOClient

    init() {
        manager = SocketManager(
            socketURL: URL(string: "https://example.com")!,
            config: [
                .log(false)
            ]
        )

        socket = manager.defaultSocket

        socket.on(clientEvent: .connect) { _, _ in
            print("Connected")
        }

        socket.on(clientEvent: .disconnect) { data, _ in
            print("Disconnected:", data.first ?? "")
        }

        socket.on(clientEvent: .connectError) { data, _ in
            print("Connection failed:", data)
        }

        socket.on(clientEvent: .error) { data, _ in
            print("Socket error:", data)
        }

        socket.on("message") { data, _ in
            print("Received:", data)
        }
    }

    func connect() {
        socket.connect()
    }

    func disconnect() {
        socket.disconnect()
    }

    func send(_ message: String) {
        socket.emit("message", message)
    }
}
```

Register listeners before connecting.

`autoConnect` defaults to `false`, so the socket only connects when you call:

```swift
socket.connect()
```
