Socket.IO-Client-Swift
======================

Work in progress

socket.io-client for Swift

Installation
============
1. Requires linking [SocketRocket](https://github.com/square/SocketRocket) against your xcode project.
2. Create a bridging header for SocketRocket
2. Copy the SwiftIO folder into your xcode project
3. 

Use
===

```
let socket = SocketIOClient(socketURL: "http://localhost:8080")
socket.on("connect") {data in
    println("socket connected")
    socket.emit("testEcho")
    socket.emit("testObject", args: [
        "data": true
        ])
}
socket.connect()
```
