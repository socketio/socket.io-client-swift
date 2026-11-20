# Migration overview

[Documentation index](../README.md) · [Project overview](../../README.md)

## Migrating from 17.x to 18

18.0 contains one breaking change: configured `.cookies(...)` are scoped like a browser
cookie jar (RFC 6265).

- 17.x sent every configured cookie to the Socket.IO server, whatever its domain, and
  URLSession copied the cookie to any host a redirect pointed to.
- 18.0 sends a cookie only to URLs its domain, path, `Secure` flag and expiry allow. This
  applies to the first polling and WebSocket request and to every redirect.

What to check:

- Set each cookie's domain to the Socket.IO server's host (`chat.example.com`, host-only),
  or to its parent domain with a leading dot (`.example.com`) when sibling hosts need it.
- Remove the `Secure` flag from cookies for plain `http`/`ws` servers, or connect over `https`/`wss`.
- A cookie whose path does not cover the Socket.IO path (default `/socket.io/`) is no longer sent.
- An explicit `Cookie` entry in `.extraHeaders` is still sent as written.

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
