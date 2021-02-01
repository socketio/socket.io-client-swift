# v16.0.0

- Removed Objective-C support. It's time for you to embrace Swift.
- Socket.io 3 support.

# v15.3.0

- Add `==` operators for `SocketAckStatus` and `String`

# v15.2.0

- Small fixes.

# v15.1.0

- Add ability to enable websockets SOCKS proxy.
- Fix emit completion callback not firing on websockets [#1178](https://github.com/socketio/socket.io-client-swift/issues/1178)

# v15.0.0

- Swift 5

# v14.0.0

- Minimum version of the client is now Swift 4.2.
- Add exponential backoff for reconnects, with `reconnectWaitMax` and `randomizationFactor` options [#1149](https://github.com/socketio/socket.io-client-swift/pull/1149)
- `statusChange` event's data format adds a second value, the raw value of the status. This is for use in Objective-C. [#1147](https://github.com/socketio/socket.io-client-swift/issues/1147)

# v13.4.0

- Add emits with write completion handlers. [#1096](https://github.com/socketio/socket.io-client-swift/issues/1096)
- Add ability to listen for when a websocket upgrade happens

# v13.3.1

- Fixes various bugs. [#857](https://github.com/socketio/socket.io-client-swift/issues/857), [#1078](https://github.com/socketio/socket.io-client-swift/issues/1078)

# v13.3.0

- Copy cookies from polling to WebSockets ([#1057](https://github.com/socketio/socket.io-client-swift/issues/1057), [#1058](https://github.com/socketio/socket.io-client-swift/issues/1058))

# v13.2.1

- Fix packets getting lost when WebSocket upgrade fails. [#1033](https://github.com/socketio/socket.io-client-swift/issues/1033)
- Fix bad unit tests. [#794](https://github.com/socketio/socket.io-client-swift/issues/794)

# v13.2.0

- Add ability to bypass Data inspection in emits. [#992]((https://github.com/socketio/socket.io-client-swift/issues/992))
- Allow `SocketEngine` to be subclassed

# v13.1.3

- Fix setting reconnectAttempts [#989]((https://github.com/socketio/socket.io-client-swift/issues/989))


# v13.1.2

- Fix [#950](https://github.com/socketio/socket.io-client-swift/issues/950)
- Conforming to `SocketEngineWebsocket` no longer requires conforming to `WebsocketDelegate`


# v13.1.1

- Fix [#923](https://github.com/socketio/socket.io-client-swift/issues/923)
- Fix [#894](https://github.com/socketio/socket.io-client-swift/issues/894)

# v13.1.0

- Allow setting `SocketEngineSpec.extraHeaders` after init.
- Deprecate `SocketEngineSpec.websocket` in favor of just using the `SocketEngineSpec.polling` property.
- Enable bitcode for most platforms.
- Fix [#882](https://github.com/socketio/socket.io-client-swift/issues/882). This adds a new method
`SocketManger.removeSocket(_:)` that should be called if when you no longer wish to use a socket again.
This will cause the engine to no longer keep a strong reference to the socket and no longer track it.

# v13.0.1

- Fix not setting handleQueue on `SocketManager`

# v13.0.0

Checkout out the migration guide in Usage Docs for a more detailed guide on how to migrate to this version.

What's new:
---

- Adds a new `SocketManager` class that multiplexes multiple namespaces through a single engine.
- Adds `.sentPing` and `.gotPong` client events for tracking ping/pongs.
- watchOS support.

Important API changes
---

- Many properties that were previously on `SocketIOClient` have been moved to the `SocketManager`.
- `SocketIOClientOption.nsp` has been removed. Use `SocketManager.socket(forNamespace:)` to create/get a socket attached to a specific namespace.
- Adds `.sentPing` and `.gotPong` client events for tracking ping/pongs.
- Makes the framework a single target.
- Updates Starscream to 3.0
