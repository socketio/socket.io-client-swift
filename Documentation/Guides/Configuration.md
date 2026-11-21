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

Since 18.0.0, `.cookies(...)` are scoped like a browser cookie jar (RFC 6265). Each
cookie is sent only to URLs that its domain, path, `Secure` flag and expiry allow,
on the first request and again after every redirect:

- A domain without a leading dot (`api.example.com`) is host-only: the cookie goes to that host only.
- A domain with a leading dot (`.example.com`) also covers subdomains such as `node3.example.com`.
  An IP address only matches itself, never as a domain suffix.
- The path is compared with the percent-encoded request path, on a `/` boundary.
- A `Secure` cookie is never sent over `http`/`ws`.
- Cookies are not port-scoped, so another port on the same host still receives them.

Before 18.0.0, every configured cookie went to the server whatever its domain, and
URLSession copied it to any host a redirect pointed to. Give each cookie the domain
of your Socket.IO server, or that server's parent domain with a leading dot.

An explicit `Cookie` entry in `.extraHeaders` replaces `.cookies` (and, for the
WebSocket handshake, the `.withCredentials` jar). It is sent as written, without
scoping, to the configured server host on any scheme or port, including after an
`http` → `https` or port redirect. A redirect to another host never receives it.

### Redirects

The client follows redirects like the Kotlin client:

| Request | Redirect |
| --- | --- |
| Polling GET | Followed for every 3xx status, also to another origin. |
| Polling POST | Only 307/308 to the host of the first request, see below. |
| WebSocket handshake | Never followed. The handshake fails, as in browsers and Node's `ws`. |

On every redirect:

- `https`/`wss` is never downgraded to `http`/`ws`, checked against the current hop and the first request.
- When the origin (scheme, host or port) changes, `Authorization` and `Proxy-Authorization`
  are removed, also when they come from `.extraHeaders`. They do not come back on a later
  hop to the first origin.
- `Cookie` is rebuilt for the new URL from `.cookies` and the `.withCredentials` jar by the
  rules above; an explicit `Cookie` from `.extraHeaders` only goes to the configured host.
  Other `.extraHeaders` follow the redirect, as in browsers and curl.
- With a `.clientCertificate`, a redirect to another origin is refused before a connection
  to the target is made, so the certificate is never presented there and the request does
  not silently continue without it. The request fails with the 3xx response.
- A `.sessionDelegate` cannot widen these rules: a refused redirect is not offered to it,
  and the request it returns is checked again.

A refused redirect fails the request like a transport error, which starts the usual
reconnection; for a WebSocket upgrade from polling, the connection stays on polling. To
move the connection to another host, configure the client with that host's URL.

#### Polling POSTs

A polling POST carries Engine.IO packets, including the CONNECT `auth` payload, so since
18.0.0 it follows a redirect only when all of these hold:

- the status is 307 or 308, so the method and body stay unchanged;
- the target is on the host of the first request (another scheme or port is fine);
- a `.sessionDelegate` that handles the redirect still returns a POST to that host.

Otherwise the request is not followed and the write fails with the 3xx response.
URLSession would turn the POST into a GET without body on 301, 302 and 303, losing the
packets while the write looked successful, and would resend the body to any host on 307
and 308.

`SocketEngine.setConfigs(_:)` replaces the whole configuration: options it omits,
including credentials and the TLS policy, return to their defaults. Pass the complete
configuration, as `SocketManager` does. Turning `.withCredentials` off also empties the
engine's cookie jar, so cookies a server set for one session are not sent in a later one.

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
