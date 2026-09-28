# Architecture and source map

[Documentation index](../README.md) · [Project overview](../../README.md)

## Architecture

At a high level:

```text
SocketIOClient
      │
      │ namespace / events / acks
      ▼
SocketManager
      │
      │ Socket.IO protocol
      ▼
SocketEngine
      │
      │ Engine.IO 4
      ├───────────────┐
      ▼               ▼
HTTP Polling      WebSocket
(URLSession)      (URLSessionWebSocketTask)
```

A SocketManager owns the Engine.IO connection and can multiplex multiple SocketIOClient namespaces over it.

Most applications should interact only with:

- SocketManager
- SocketIOClient
- SocketIOClientOption

Direct Engine.IO classes are implementation-level APIs for specialized use and testing.

## Source organization

| Directory under `Source/SocketIO` | Responsibility |
| --- | --- |
| `Client` | Namespace lifecycle, application events, listeners and configuration API |
| `Manager` | Shared Engine.IO connection, namespace ownership and reconnect coordination |
| `Ack` | Acknowledgement registration, timeout/async wrappers and completion errors |
| `Engine` | Engine.IO framing, polling, heartbeats and transport upgrades |
| `Engine/Transport` | Internal URLSession WebSocket adapter and bounded message queues |
| `Parse` | Socket.IO packet encoding, parsing and binary reconstruction |
| `Security` | TLS policy, trust evaluation and session-delegate routing |
| `Util` | Shared payload types, buffer limits, extensions and logging |

`Package.swift` intentionally points at `Source/SocketIO`; the directory does not
have to be renamed to load as a Swift package. Keeping these paths stable also
keeps source references in the parity history useful.

## Ownership boundaries

Retain the manager for as long as its sockets are needed. The manager owns the
shared engine, while a client represents one namespace. Application-side access
belongs to the manager's serial `handleQueue`, the main queue by default.
The async APIs do not make the manager or clients generally Sendable.

The engine separates polling and WebSocket sessions. Callback generation and
session identity checks prevent a retired connection from changing a newer
connection's state. An RFC 6455 WebSocket opening is not an Engine.IO handshake;
Socket.IO namespace connection is another distinct stage after that.

See the [native transport design](../NativeWebSocketTransport.md#runtime-architecture)
for upgrade ordering and shutdown behavior, and the
[concurrency contract](../SocketIO4Swift6Migration.md#concurrency-and-asynchronous-callbacks)
for async authentication and acknowledgement ownership.

## Tests and protocol evidence

Unit tests and mocks live in `Tests/TestSocketIO`; real-server suites and their
fixtures live in its `E2E` directory. The contract manifest points to exact files
and method names. The [testing guide](Testing.md) explains the distinction between
native executions, upstream reference executions, parser comparisons and SDK builds.
