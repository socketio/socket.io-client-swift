# Troubleshooting

[Documentation index](../README.md) · [Project overview](../../README.md)

## Debugging

Enable logging during development:

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .log(true)
    ]
)
```

Do not enable verbose socket logging in production when authentication data or sensitive application payloads may appear in logs.

When debugging connection problems, check these first:

- Is the endpoint actually a Socket.IO 4 server rather than a raw WebSocket server?
- Is the configured .path(...) identical to the server's Socket.IO path?
- Can HTTP long-polling reach the server?
- Can the server upgrade that session to WebSocket?
- Is a reverse proxy forwarding both polling and WebSocket traffic correctly?
- Is authentication expected in the Socket.IO auth payload, HTTP headers or query parameters?
- If forcing WebSocket, does the infrastructure allow direct WebSocket handshakes?
- Does the problem reproduce without .forceWebsockets(true)?

.connectError is generally the first event to inspect for failures while establishing a connection:

```swift
socket.on(clientEvent: .connectError) { data, _ in
    print(data)
}
```

For failures after an established connection, inspect both .error and .disconnect.

## Is this a plain WebSocket client?

No. The server must implement Socket.IO 4. A WebSocket endpoint alone does not
implement the Engine.IO and Socket.IO handshakes. Use a plain WebSocket API for
a server that only speaks WebSocket; changing the URL scheme is not a conversion.

## Why is my event handler never called?

Keep a strong reference to the `SocketManager` and register listeners before
connecting. This loses its local manager when `addHandlers()` returns:

```swift
final class IncorrectOwner {
    func addHandlers() {
        let manager = SocketManager(socketURL: URL(string: "https://example.com")!)
        manager.defaultSocket.on("myEvent") { data, _ in
            print(data)
        }
    }
}
```

Retain it as a property instead, and actually connect:

```swift
@MainActor
final class ConnectionOwner {
    let manager = SocketManager(socketURL: URL(string: "https://example.com")!)

    func connect() {
        manager.defaultSocket.on("myEvent") { data, _ in
            print(data)
        }
        manager.defaultSocket.connect()
    }
}
```

Call this setup once per owner, or remove old listener IDs before registering
again. The owning `ConnectionOwner` must also outlive the connection.

## Is the namespace the same as the HTTP path?

No. `.path("/socket.io/")` selects the Engine.IO HTTP endpoint. Use
`manager.socket(forNamespace: "/chat")` to join a Socket.IO namespace. Check both
independently against the server configuration.

## Does an acknowledgement timeout prove the event failed?

No. The server may have processed it even though its acknowledgement did not
arrive. Retrying can produce duplicates. See
[acknowledgements and delivery](Acknowledgements.md#automatic-retries).

## Why do local tests skip or fail to start fixtures?

Install the pinned Node fixture dependencies and check Node/OpenSSL availability
before running the suite. See [testing prerequisites](../Development/Testing.md#local-setup).

## What should a useful bug report contain?

Include the exact client revision, Xcode/Swift and OS versions, server version,
transport configuration, a minimal reproducer and sanitized lifecycle logs.
Do not publish access tokens, cookies, private keys or personal payloads.
See [contributing](../../CONTRIBUTING.md).
