# Acknowledgements and delivery

[Documentation index](../README.md) · [Project overview](../../README.md)

Examples assume an existing socket accessed on its serial `handleQueue`. Call async methods from the corresponding isolation context; async/await does not make the socket generally Sendable.

## Acknowledgements

Socket.IO acknowledgements let the server confirm or respond to an event.

For new code, prefer the typed timeout API or the async API.

### Callback

```swift
socket.timeout(after: 5).emit("createOrder", ["item": "coffee"]) { error, data in
    if let error {
        print("Acknowledgement failed:", error)
        return
    }

    print("Server response:", data)
}
```

Timeout values in the Swift API are specified in seconds.

A timeout means that no acknowledgement was received in time. It does not prove that the server did not process the event.

### async / await

```swift
do {
    let response = try await socket
        .timeout(after: 5)
        .emitWithAck("createOrder", ["item": "coffee"])

    print(response)
} catch SocketAckError.timeout {
    print("Server did not acknowledge in time")
} catch SocketAckError.disconnected {
    print("Socket disconnected before the acknowledgement")
} catch is CancellationError {
    print("Task was cancelled")
} catch {
    print("Acknowledgement failed:", error)
}
```

You can also use:

```swift
let response = try await socket.emitWithAck("event", "value")
```

When no explicit timeout is supplied, this uses the effective ackTimeout configured for the socket.

### Default acknowledgement timeout

Configure a default:

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .ackTimeout(5)
    ]
)
```

Or override it for one namespace:

```swift
socket.ackTimeout = 3
```

### Automatic retries

Socket.IO-style ordered retries are available with:

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .ackTimeout(5),
        .retries(2)
    ]
)
```

This means:

- one initial attempt
- up to two retries
- retries occur when the required acknowledgement does not arrive

Retries may cause an event to reach the server more than once.

For operations that must be idempotent, include an application-level event ID and deduplicate on the server.

A namespace can override the manager defaults:

```swift
socket.ackTimeout = 2
socket.retries = 1
```

Restore the manager defaults with:

```swift
socket.resetDeliveryOptions()
```

### Legacy acknowledgement API

The historical API remains available:

```swift
socket.emitWithAck("event", "value")
    .timingOut(after: 5) { data in
        print(data)
    }
```

New code should generally prefer timeout(after:) or the async acknowledgement API because they provide typed errors and clearer disconnect semantics.

### Acknowledging incoming events

A server may request an acknowledgement from the client.

```swift
socket.on("question") { data, ack in
    guard ack.expected else { return }

    ack.with("received")
}
```
