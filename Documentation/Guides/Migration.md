# Migration overview

[Documentation index](../README.md) · [Project overview](../../README.md)

## Migrating from 17.x to 18

The main breaking change in 18.0: configured `.cookies(...)` are scoped like a browser
cookie jar (RFC 6265).

- 17.x sent every configured cookie to the Socket.IO server, whatever its domain, and
  URLSession copied the cookie to any host a redirect pointed to.
- 18.0 sends a cookie only to URLs its domain, path, `Secure` flag and expiry allow. This
  applies to the first polling and WebSocket request and to every redirect.

What to check:

- Set each cookie's domain to the Socket.IO server's host (`chat.example.com`, host-only),
  or to its parent domain with a leading dot (`.example.com`) when sibling hosts need it.
- Remove the `Secure` flag from cookies for plain `http`/`ws` servers, or connect over
  `https`/`wss`. Plain `http`/`ws` to `localhost`, 127.0.0.0/8 or `::1` counts as secure,
  as in browsers.
- A cookie whose path does not cover the Socket.IO path (default `/socket.io/`) is no longer sent.
- An explicit `Cookie` entry in `.extraHeaders` is still the whole `Cookie` header, sent as
  written, on the configured host on any scheme or port. A redirect to another host no
  longer receives it; that host gets the `.cookies` and server cookies scoped to it.
- With `.withCredentials`, the engine now sends and stores server cookies itself on
  polling too, so `.cookies` are no longer dropped next to them. A `Secure` cookie from a
  context that is not secure, and a `__Secure-` or `__Host-` cookie that breaks its
  prefix rules, are not stored. Cookies in the header are ordered by path length, then by
  creation (RFC 6265).
- Only 301, 302, 303, 307 and 308 redirects are followed; 300 is not. `Authorization`
  and `Proxy-Authorization` follow a redirect only within the first origin, and a `Host`
  header from `.extraHeaders` is removed when the host or port changes.
- A polling POST follows only a 307/308 redirect to the host of the first request. A
  server or proxy that answers POSTs with 301, 302 or 303, or redirects them to another
  host, now fails the write instead; see [Configuration – Redirects](Configuration.md#redirects).
- The WebSocket handshake follows no redirect. Point the client at the final WebSocket URL;
  an upgrade from polling that is redirected stays on polling.
- With `.clientCertificate`, a redirect to another scheme, host or port fails instead of
  continuing without the certificate.
- `SocketEngine.setConfigs(_:)` replaces the whole configuration, and disabling
  `.withCredentials` empties the engine's cookie jar. Code that calls `setConfigs` on an
  engine directly with a partial list must pass the complete configuration.
- `SocketManager.connectSocket(_:withPayload:)` and `joinNamespace()` without `connect()`
  connect again when the server answers (this regressed while 18.0 was in development).

Details: [Configuration – Cookies](Configuration.md#cookies).

## Migrating from 16.x to 17

17.0 is a breaking release.

The major architectural change is the move from Starscream and historical compatibility modes to a native Swift 6 / Socket.IO 4 implementation.

The most important changes are:

- Socket.IO 4 / Engine.IO 4 only
- Swift 6.2 or newer toolchain, Swift 6 language mode
- Starscream removed
- URLSessionWebSocketTask is the WebSocket backend
- .version(...) and SocketIOVersion removed
- .useCustomEngine(...) removed
- .compress removed
- .selfSigned(...) removed
- .enableSOCKSProxy(...) removed
- Reconnection events now follow modern JavaScript client semantics
- Encoding failures are reported instead of silently sending altered packets
- Modern acknowledgement timeout/retry APIs added
- Connection State Recovery added
- Transport selection/fallback behavior brought closer to the JavaScript client

Do not rely on a short README summary for a production migration.

Read:

- [Socket.IO 4 / Swift 6 migration guide](../SocketIO4Swift6Migration.md)

and:

- [Native URLSession transport migration](../NativeWebSocketTransport.md)

The complete release status and publication gates are tracked in:

- [Release 17](../Release17.md)
