Socket.IO-Client-Swift
======================

Socket.IO-client for Swift. Supports ws/wss connections and binary. For socket.io 1.0+ and Swift 1.1.

For Swift 1.2 use the 1.2 branch.

Installation
============
1. Requires linking [SocketRocket](https://github.com/square/SocketRocket) against your xcode project. (Be sure to link the [frameworks](https://github.com/square/SocketRocket#framework-dependencies) required by SocketRocket)
2. Create a bridging header for SocketRocket
3. Copy the SwiftIO folder into your xcode project

API
===
Constructor
-----------
`init(socketURL: String, opts:[String: AnyObject]? = nil)` - Constructs a new client for the given URL. opts can be omitted (will use default values.)
Methods
-------
1. `socket.on(name:String, callback:((data:NSArray?, ack:AckEmitter?) -> Void))` - Adds a handler for an event. Items are passed by an array. `ack` can be used to send an ack when one is requested. See example.
3. `socket.emit(event:String, args:AnyObject...)` - Sends a message. Can send multiple args.
4. `socket.emitWithAck(event:String, args:AnyObject...) -> SocketAckHandler` - Sends a message that requests an acknoweldgement from the server. Returns a SocketAckHandler which you can use to add an onAck handler. See example.
5. `socket.connect()` - Establishes a connection to the server. A "connect" event is fired upon successful connection.
6. `socket.connectWithParams(params:[String: AnyObject])` - Establishes a connection to the server passing the specified params. A "connect" event is fired upon successful connection.
7. `socket.close()` - Closes the socket. Once a socket is closed it should not be reopened.

Events
------
1. `connect` - Emitted when on a successful connection.
2. `disconnect` - Emitted when the connection is closed.
3. `error` - Emitted if the websocket encounters an error.
4. `reconnect` - Emitted when the connection is starting to reconnect.
5. `reconnectAttempt` - Emitted when attempting to reconnect.

Example
=======
```swift
// opts can be omitted, will use default values
let socket = SocketIOClient(socketURL: "https://localhost:8080", opts: [
    "reconnects": true, // default true
    "reconnectAttempts": 5, // default -1 (infinite tries)
    "reconnectWait": 5, // default 10
    "nsp": "swift" // connects to the specified namespace. Default is /
])

// Socket Events
socket.on("connect") {data, ack in
    println("socket connected")

    // Sending messages
    socket.emit("testEcho")

    socket.emit("testObject", [
        "data": true
        ])

    // Sending multiple items per message
    socket.emit("multTest", [1], 1.4, 1, "true",
        true, ["test": "foo"], "bar")
}

// Requesting acks, and responding to acks
socket.on("ackEvent") {data, ack in
    if let str = data?[0] as? String {
        println("Got ackEvent")
    }

    socket.emitWithAck("ackTest", "test").onAck {data in
        println(data?[0])
    }

    ack?("Got your event", "dude")
}

socket.on("disconnect") {data, ack in
    if let reason = data?[0] as? String {
        println("Socket disconnected: \(reason)")
    }
}

socket.on("reconnect") {data, ack in
    if let reason = data?[0] as? String {
        println("Socket reconnecting: \(reason)")
    }
}

socket.on("reconnectAttempt") {data, ack in
    if let triesLeft = data?[0] as? Int {
        println(triesLeft)
    }
}
// End Socket Events

socket.on("jsonTest") {data, ack in
    if let json = data?[0] as? NSDictionary {
       println(json["test"]!) // foo bar
    }
}

// Event items are passed by an array
socket.on("multipleItems") {data, ack in
    if data == nil {
        return
    }

    if let str = data![0] as? String {
        println(str)
    }

    if let arr = data![1] as? [Int] {
        println(arr)
    }

    if let obj = data![4] as? NSDictionary {
        println(obj["test"])
    }
}

// Recieving binary
socket.on("dataTest") {data, ack in
    if let data = data?[0] as? NSData {
        println("data is binary")
    }
}

socket.on("objectDataTest") {data, ack in
    if let dict = data?[0] as? NSDictionary {
        if let data = dict["data"] as? NSData {
            let string = NSString(data: data, encoding: NSUTF8StringEncoding)
            println("Got data: \(string!)")
        }
    }
}

// Connecting
socket.connect()

// Sending binary
socket.emit("testData", [
        "data": "Hello World".dataUsingEncoding(NSUTF8StringEncoding,
            allowLossyConversion: false)!,
        "test": true])
```
License
=======
MIT
