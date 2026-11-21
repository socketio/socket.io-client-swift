# Socket.IO-Client-Swift 18.0.0

Release dated 2026-11-21, distributed through Swift Package Manager with the
immutable [`v18.0.0` tag](https://github.com/kaeferfreund/socket.io-client-swift/releases/tag/v18.0.0).
Requires Swift 6.2 / Xcode 26 or newer; deployment targets remain iOS/tvOS 15, macOS 12 and
watchOS 9. Socket.IO 4 / Engine.IO 4 over polling and WebSocket remain the protocol scope.

18.0.0 is a major release because redirect and cookie handling changed. Both now follow
RFC 9110, RFC 6265 and the relevant parts of RFC 6265bis. They match the Kotlin client
17.2.0 ([kaeferfreund/socket.io-client-kotlin](https://github.com/kaeferfreund/socket.io-client-kotlin))
rule for rule.

## Breaking changes

- **Cookies are scoped and stored like a browser cookie jar (RFC 6265).**
  - Configured `.cookies` and the cookies the server set (`.withCredentials`) go only to
    URLs their domain, path, `Secure` flag and expiry allow, on the first request and on
    every redirect hop.
  - The engine sends and stores all cookies itself, in one `Cookie` header: longer paths
    first, then oldest first.
  - An explicit `Cookie` from `.extraHeaders` is the whole header on the configured host
    and is never sent to another host.
  - Server cookies are stored for the URL that answered. The client ignores:
    - a `Secure` cookie from a context that is not secure;
    - a cookie from plain http that would replace or shadow a `Secure` cookie;
    - a `__Secure-` or `__Host-` cookie that breaks its prefix rules.
  - Plain http/ws to `localhost`, 127.0.0.0/8 and `::1` is a secure context.
  - Hosts are compared in canonical form: WHATWG IPv4, canonical IPv6, no trailing dot.
- **Redirects follow stricter rules.**
  - Only 301, 302, 303, 307 and 308 are followed.
  - A polling POST follows only 307/308 to the host of the first request.
  - The WebSocket handshake follows no redirect.
  - https/wss is never downgraded.
  - With a `.clientCertificate`, a redirect to another origin is refused.
  - `Authorization` and `Proxy-Authorization` stay within the first origin and do not
    come back after leaving it.
  - A `Host` from `.extraHeaders` is removed when host or port change.
  - A `.sessionDelegate` cannot widen these rules.
- **`SocketEngine.setConfigs(_:)` replaces the whole configuration**, and turning
  `.withCredentials` off empties the engine's cookie jar.

See the [CHANGELOG](../CHANGELOG.md) for every fix and the
[migration guide](Guides/Migration.md#migrating-from-17x-to-18) for what to check, and
[Configuration – Cookies](Guides/Configuration.md#cookies) and
[Configuration – Redirects](Guides/Configuration.md#redirects) for the exact rules.

## Background

- URLSession copies an app-set `Cookie` header to any host a redirect points to.
  `URLSessionWebSocketTask` does the same for the WebSocket handshake, and both drop
  `Authorization` even on a redirect to the same origin. This was verified on macOS 27
  and reported to Apple as OE11044480357213.
- The client now decides every redirect hop itself instead of relying on that behaviour.

## Validation

- The release candidate is validated by the repository's release workflow:
  - the native suite and real-server tests;
  - the full suite on the declared `swift-tools-version` floor;
  - independent SPM consumers;
  - Thread Sanitizer and strict concurrency;
  - Apple SDK builds;
  - protocol proofs, parser parity and pinned upstream client suites;
  - documentation checks and repository hygiene.
- `RedirectCredentialsE2ETest` runs every redirect and cookie rule above through a real
  URLSession against Node fixtures.
- Before release, the changes went through a multi-model review: Fable, Opus, Codex,
  Gemini, Kimi, GLM, Muse, Grok and CodeRabbit, with Fable adjudicating the findings.
  Every confirmed finding was fixed.
