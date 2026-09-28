# Migration overview

[Documentation index](../README.md) · [Project overview](../../README.md)

## Migrating from 16.x to 17

17.0 is a breaking release.

The major architectural change is the move from Starscream and historical compatibility modes to a native Swift 6 / Socket.IO 4 implementation.

The most important changes are:

- Socket.IO 4 / Engine.IO 4 only
- Swift 6.4 toolchain, Swift 6 language mode
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
