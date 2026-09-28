# Authentication and connection lifecycle

[Documentation index](../README.md) · [Project overview](../../README.md)

Examples assume an existing socket used on its serial `handleQueue`. `accessToken` and `newAccessToken` stand for application credentials. The async `tokenProvider` must be safe to access from a `@Sendable` provider, for example an actor. See the [concurrency contract](../SocketIO4Swift6Migration.md#concurrency-and-asynchronous-callbacks).

## Authentication

### Static connection payload

For a simple authentication payload:

```swift
socket.connect(
    withPayload: [
        "token": accessToken
    ]
)
```

The payload is sent in the Socket.IO namespace CONNECT packet.

This is different from HTTP headers and URL query parameters.

### Dynamic authentication

When credentials can change between reconnects, use an auth provider.

Callback provider:

```swift
socket.setAuth { callback in
    callback([
        "token": accessToken
    ])
}
```

The provider is evaluated for every CONNECT, including reconnects.

Async provider:

```swift
socket.setAuth {
    let token = try await tokenProvider.accessToken()

    return [
        "token": token
    ]
}
```

If the async provider throws, the connection attempt fails closed and an .error client event is emitted.

Remove the provider with:

```swift
socket.clearAuth()
```

### HTTP headers

If your server expects HTTP authentication instead:

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .extraHeaders([
            "Authorization": "Bearer \(accessToken)"
        ])
    ]
)
```

Use .connectParams(...) only when your server intentionally expects URL query parameters.

Avoid putting long-lived credentials into URLs.

## Namespaces

A single SocketManager can multiplex multiple Socket.IO namespaces over one Engine.IO connection.

Since 17.0.1, `manager.defaultSocket` uses the namespace in the manager URL path:
`https://example.com/admin` selects `/admin`. An empty path or `/` selects root.
Use `manager.socket(forNamespace: "/")` to explicitly select root regardless of
the URL. The `.path(...)` option separately configures the HTTP/WebSocket endpoint;
it does not select a namespace.

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!
)

let chat = manager.socket(forNamespace: "/chat")
let notifications = manager.socket(forNamespace: "/notifications")

chat.on("message") { data, _ in
    print("Chat:", data)
}

notifications.on("notification") { data, _ in
    print("Notification:", data)
}

chat.connect()
notifications.connect()
```

Calling socket(forNamespace:) repeatedly with the same namespace returns the same managed socket.

Keep a strong reference to the manager. The socket itself does not own the manager.

## Reconnection

Automatic reconnection is enabled by default.

Default reconnect behavior:

| Option | Default |
| --- | --- |
| reconnects | true |
| reconnectAttempts | unlimited |
| reconnectWait | 1 second |
| reconnectWaitMax | 5 seconds |
| randomizationFactor | 0.5 |
| connectTimeout | 20 seconds |

The reconnect backoff follows the modern Socket.IO client behavior.

Useful lifecycle events:

```swift
socket.on(clientEvent: .disconnect) { data, _ in
    print("Disconnected:", data.first ?? "")
}

socket.on(clientEvent: .reconnectAttempt) { data, _ in
    print("Reconnect attempt:", data.first ?? "")
}

socket.on(clientEvent: .reconnectError) { data, _ in
    print("Reconnect attempt failed:", data.first ?? "")
}

socket.on(clientEvent: .reconnect) { data, _ in
    print("Transport reconnected after attempt:", data.first ?? "")
}

socket.on(clientEvent: .reconnectFailed) { _, _ in
    print("Reconnect attempts exhausted")
}
```

A successful transport reconnection emits .reconnect, followed by .connect after the Socket.IO namespace has been joined again.

An intentional:

```swift
socket.disconnect()
```

does not immediately start an automatic reconnect. Call connect() again when you want to rejoin.

## Connection State Recovery

Socket.IO 4.6+ can optionally recover a previous Socket.IO session after a temporary connection loss.

The server must have connectionStateRecovery configured.

Check:

```swift
socket.on(clientEvent: .connect) { [weak socket] _, _ in
    guard let socket else { return }

    if socket.recovered {
        print("Previous session recovered")
    } else {
        print("Fresh session")
    }
}
```

When recovery succeeds, missed server-to-client events can be replayed by the server.

Recovery is not guaranteed. Application code must still handle a completely fresh connection.

### Changing authenticated users

Recovery state belongs to the current logical session.

When switching identities, clear it before reconnecting:

```swift
socket.clearRecoveryState()
socket.disconnect()

socket.connect(
    withPayload: [
        "token": newAccessToken
    ]
)
```

clearRecoveryState() also discards pending buffered/retry state associated with the previous identity.
