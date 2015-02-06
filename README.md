Socket.IO-Client-Swift
======================

Socket.IO-client for Swift. Supports ws/wss connections and binary. For socket.io 1.0+

Installation
============
1. Requires linking [SocketRocket](https://github.com/square/SocketRocket) against your xcode project. (Be sure to link the [frameworks](https://github.com/square/SocketRocket#framework-dependencies) required by SocketRocket)
2. Create a bridging header for SocketRocket
3. Copy the SwiftIO folder into your xcode project

API
===
Constructor
-----------
`init(socketURL: String, opts[String: AnyObject]? = nil)` - Constructs a new client for the given URL. opts can be omitted (will use default values.)
Methods
-------
1. `socket.on(name:String, callback:((data:AnyObject?) -> Void))` - Adds a handler for an event.
2. `socket.onMultipleItems(name:String, callback:((data:NSArray?) -> Void))` - Adds a handler for an event that           can have multiple items. Items are stored in an array.
3. `socket.emit(event:String, args:AnyObject...)` - Sends a message. Can send multiple args.
4. `socket.connect()` - Establishes a connection to the server. A "connect" event is fired upon successful connection.
5. `socket.close()` - Closes the socket. Once a socket is closed it should not be reopened.

Events
------
1. `connect` - Emitted when on a successful connection.
2. `disconnect` - Emitted when the connection is closed.
3. `error` - Emitted if the websocket encounters an error.
4. `reconnect` - Emitted when the connection is starting to reconnect.
5. `reconnectAttempt` - Emitted when attempting to reconnect.

```swift
// opts can be omitted, will use default values
let socket = SocketIOClient(socketURL: "https://localhost:8080", opts: [
    "reconnects": true, // default true
    "reconnectAttempts": 5, // default -1 (infinite tries)
    "reconnectWait": 5, // default 10
    "nsp": "swift" // connects to the specified namespace. Default is /
])

// Socket Events
socket.on("connect") {data in
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

socket.on("disconnect") {data in
    if let reason = data as? String {
        println("Socket disconnected: \(reason)")
    }
}

socket.on("reconnect") {data in
    if let reason = data as? String {
        println("Socket reconnecting: \(reason)")
    }
}

socket.on("reconnectAttempt") {data in
    if let triesLeft = data as? Int {
        println(triesLeft)
    }
}
// End Socket Events

socket.on("jsonTest") {data in
    if let json = data as? NSDictionary {
       println(json["test"]!) // foo bar
    }
}

// Messages that have multiple items are passed
// by an array
socket.onMultipleItems("multipleItems") {data in
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
socket.on("dataTest") {data in
    if let data = data as? NSData {
        println("data is binary")
    }
}

socket.on("objectDataTest") {data in
    if let dict = data as? NSDictionary {
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
