# Configuration and concurrency

[Documentation index](../README.md) · [Project overview](../../README.md)

The examples show individual options; combine them in the configuration of your retained manager. Certificate variables contain application-provided DER data. For the full API, see [SocketIOClientOption](../../Source/SocketIO/Client/SocketIOClientOption.swift).

## Transport configuration

The default connection starts with HTTP long-polling and upgrades to WebSocket when possible.

For most applications, no transport configuration is necessary.

### WebSocket only

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .forceWebsockets(true)
    ]
)
```

### Polling only

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .forcePolling(true)
    ]
)
```

Do not enable both simultaneously.

### Explicit transport order

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .transports([
            .websocket,
            .polling
        ]),
        .tryAllTransports(true)
    ]
)
```

tryAllTransports(true) lets the client try the next configured transport when the initial transport cannot establish the connection.

rememberUpgrade(true) can prefer WebSocket on later connections after WebSocket has previously succeeded.

## Common configuration

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .path("/socket.io/"),
        .connectTimeout(20),
        .reconnects(true),
        .reconnectAttempts(-1),
        .reconnectWait(1),
        .reconnectWaitMax(5),
        .randomizationFactor(0.5),
        .log(false)
    ]
)
```

Frequently used options:

| Option | Purpose |
| --- | --- |
| .autoConnect(Bool) | Connect automatically when the manager/socket is created |
| .path(String) | Socket.IO HTTP endpoint |
| .connectParams(...) | Connection query parameters |
| .extraHeaders(...) | Additional HTTP headers |
| .connectTimeout(Double) | Engine.IO handshake timeout |
| .requestTimeout(Double) | Per-polling-request idle and total timeout, in seconds (17.0.1+) |
| .clientCertificate(URLCredential) | Client identity for mutual TLS (17.0.1+) |
| .reconnects(Bool) | Enable/disable automatic reconnect |
| .reconnectAttempts(Int) | Reconnect attempt budget, -1 = unlimited |
| .reconnectWait(Int) | Initial reconnect delay |
| .reconnectWaitMax(Int) | Maximum reconnect delay |
| .randomizationFactor(Double) | Reconnect jitter |
| .ackTimeout(Double) | Default server acknowledgement timeout |
| .retries(Int) | Automatic acknowledgement-based retry count |
| .forceWebsockets(Bool) | WebSocket only |
| .forcePolling(Bool) | Polling only |
| .transports(...) | Ordered initial transport candidates |
| .tryAllTransports(Bool) | Fall back to another transport on opening failure |
| .rememberUpgrade(Bool) | Prefer WebSocket after previous WebSocket success |
| .withCredentials(Bool) | Accept and resend server cookies |
| .log(Bool) | Debug logging |
| .handleQueue(DispatchQueue) | Serial queue owning client interaction |

For the complete set, see SocketIOClientOption.

## Polling request timeout and client certificates (17.0.1)

`.requestTimeout(120)` applies a positive finite limit of 120 seconds to each
polling handshake, GET and POST. It leaves WebSocket settings unchanged. The
manager connect timeout and heartbeat deadline remain independent. Omission keeps
Foundation defaults; unlike JavaScript's milliseconds/unset timeout, Swift uses
seconds and requires positive finite values.

`.clientCertificate(credential)` accepts a `URLCredential` created from a client
identity and optional intermediate certificates. Polling and WebSocket use the
same identity while retaining normal server trust checks. Credentials are limited
to the configured TLS host and port. See [native transport configuration](../NativeWebSocketTransport.md)
for examples and the detailed timeout/TLS behavior.

## Cookies

Automatic server cookie handling is opt-in:

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .withCredentials(true)
    ]
)
```

When enabled, the engine maintains its own isolated cookie jar.

The application's shared cookie store is not used automatically.

Explicit .cookies(...) and explicit Cookie headers remain available when your application wants to control cookies directly.

## Threading and Swift concurrency

SocketManager and SocketIOClient use an explicit serial-queue ownership model.

The default handleQueue is:

```swift
DispatchQueue.main
```

All client interaction should happen on the manager's configured handleQueue.

If you provide your own queue:

```swift
let socketQueue = DispatchQueue(label: "com.example.socket")

let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .handleQueue(socketQueue)
    ]
)
```

it must be serial.

Event handlers execute on that queue.

Move UI work to the main queue when necessary:

```swift
socket.on("message") { data, _ in
    DispatchQueue.main.async {
        // Update UI
    }
}
```

SocketManager and SocketIOClient deliberately do not claim general Sendable semantics.

The async acknowledgement APIs safely bridge their returned wire values across the Swift concurrency boundary, but that does not make arbitrary concurrent mutation of the socket or its payload objects safe.

## TLS

For normal HTTPS/WSS servers, no TLS configuration is required.

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!
)
```

Apple's normal system trust validation is used for both polling and WebSocket.

### Certificate pinning

Use:

```swift
.security(
    .certificatePinning([
        certificateData
    ])
)
```

Certificates are DER-encoded.

### Private CA / private trust anchor

Use:

```swift
.security(
    .customTrust(
        anchors: [caCertificateData],
        pins: []
    )
)
```

Custom trust does not disable hostname, validity-period or chain checks.

For detailed TLS examples, see [Native transport and TLS configuration](../NativeWebSocketTransport.md#tls).

## Resource limits

Normal applications do not need to configure protocol limits.

The library nevertheless provides opt-in resource controls for environments that need explicit bounds.

There are three independent layers:

- SocketParserOptions — individual Socket.IO packets and binary reconstruction
- SocketWebSocketOptions — native WebSocket messages and pending WebSocket writes
- SocketBufferLimits — retained queues and pipeline backlogs

Example:

```swift
let manager = SocketManager(
    socketURL: URL(string: "https://example.com")!,
    config: [
        .parserOptions(
            SocketParserOptions(
                maximumBinaryPacketBytes: 1 << 20,
                maximumTextPacketBytes: 1 << 20
            )
        )
    ]
)
```

Pipeline-wide limits are intentionally unlimited by default where Socket.IO's JavaScript client also has no equivalent bound.

For applications processing untrusted or unusually high-volume input, see:

- SocketParserOptions
- SocketWebSocketOptions
- SocketBufferLimits
