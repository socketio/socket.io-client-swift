# Events and payloads

[Documentation index](../README.md) · [Project overview](../../README.md)

## Receiving events

Register a listener with on:

```swift
socket.on("chatMessage") { data, ack in
    guard
        let message = data.first as? [String: Any],
        let text = message["text"] as? String
    else {
        return
    }

    print(text)
}
```

Use once for a single invocation:

```swift
socket.once("ready") { data, ack in
    print("Server is ready")
}
```

on and once return an identifier that can later remove exactly that listener:

```swift
let listener = socket.on("message") { data, _ in
    print(data)
}

socket.off(id: listener)
```

Remove all listeners for an event with:

```swift
socket.off("message")
```

## Sending events

Send an event with one or more SocketData values:

```swift
socket.emit("message", "Hello from Swift")
socket.emit(
    "updateProfile",
    [
        "name": "Ada",
        "active": true
    ]
)
```

Supported payload values include the usual JSON-compatible Swift/Foundation values, binary Data, and Date.

Date is encoded as an ISO-8601 timestamp compatible with JavaScript's Date.prototype.toJSON() representation.

You can also use Socket.IO's "message" shortcut:

```swift
socket.send("Hello")
```

which is equivalent to:

```swift
socket.emit("message", "Hello")
```

### Custom payload types

Your own types can conform to SocketData:

```swift
struct User: SocketData {
    let id: Int
    let name: String

    func socketRepresentation() -> SocketData {
        [
            "id": id,
            "name": name
        ]
    }
}
```

Then emit them normally:

```swift
socket.emit("user", User(id: 42, name: "Ada"))
```

## Volatile events

Volatile events are useful for frequently updated state where dropping an event is preferable to buffering stale data.

Examples include:

- cursor positions
- live location updates
- typing indicators
- telemetry
- continuously changing UI state

```swift
socket.volatile.emit(
    "cursor",
    [
        "x": 120,
        "y": 240
    ]
)
```

If the current transport cannot write the event immediately, a volatile event is dropped instead of being placed in the normal send buffer.

## Catch-all listeners

Listen to arbitrary incoming application events:

```swift
socket.onAny { event in
    print(event.event, event.items ?? [])
}
```

For multiple independently removable catch-all listeners:

```swift
let id = socket.addAnyListener { event in
    print(event.event)
}

socket.removeAnyListener(id: id)
```

Outgoing application events can also be observed:

```swift
let id = socket.addAnyOutgoingListener { event in
    print("Sending:", event.event)
}

socket.removeAnyOutgoingListener(id: id)
```
