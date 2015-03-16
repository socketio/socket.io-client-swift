Socket.IO-Client-Swift
======================

Socket.IO-client for Swift. Supports ws/wss/polling connections and binary. For socket.io 1.0+ and Swift 1.1.

For Swift 1.2 use the 1.2 branch.

Installation
============

Manually (iOS 7+)
-----------------
1. Copy the SwiftIO folder into your Xcode project!

CocoaPods 0.36.0 or later (iOS 8+)
------------------
Create `Podfile` and add `pod 'Socket.IO-Client-Swift'`:

```ruby
source 'https://github.com/CocoaPods/Specs.git'
platform :ios, '8.0'
use_frameworks!

pod 'Socket.IO-Client-Swift', '~> 1.1'
```

Install pods:

```
$ pod install
```

Import in your swift file:

```swift
import Socket_IO_Client_Swift
```

API
===
Constructors
-----------
`init(socketURL: String, opts:NSDictionary? = nil)` - Constructs a new client for the given URL. opts can be omitted (will use default values. See example)

`convenience init(socketURL: String, options:NSDictionary?)` - Same as above, but meant for Objective-C. See Objective-C Example.
Methods
-------
1. `socket.on(name:String, callback:((data:NSArray?, ack:AckEmitter?) -> Void))` - Adds a handler for an event. Items are passed by an array. `ack` can be used to send an ack when one is requested. See example.
2. `socket.onAny(callback:((event:String, items:AnyObject?)) -> Void)` - Adds a handler for all events. It will be called on any received event.
3. `socket.emit(event:String, args:AnyObject...)` - Sends a message. Can send multiple args.
4. `socket.emitObjc(event:String, args:[AnyObject])` - `emit` for Objective-C
5. `socket.emitWithAck(event:String, args:AnyObject...) -> SocketAckHandler` - Sends a message that requests an acknowledgement from the server. Returns a SocketAckHandler which you can use to add an onAck handler. See example.
6. `socket.emitWithAckObjc(event:String, _ args:[AnyObject]) -> SocketAckHandler` - `emitWithAck` for Objective-C.
7. `socket.connect()` - Establishes a connection to the server. A "connect" event is fired upon successful connection.
8. `socket.connectWithParams(params:[String: AnyObject])` - Establishes a connection to the server passing the specified params. A "connect" event is fired upon successful connection.
9. `socket.close()` - Closes the socket. Once a socket is closed it should not be reopened.

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
    "nsp": "swift", // connects to the specified namespace. Default is /
    "forcePolling": true // if true, the socket will only use XHR polling, default is false (polling/WebSockets)
])

// Called on every event
socket.onAny {println("got event: \($0.event) with items \($0.items)")}

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

    // data is an array
    if let int = data?[1] as? Int {
        println("Got int")
    }

    // You can specify a custom timeout interval. 0 means no timeout.
    socket.emitWithAck("ackTest", "test").onAck(0) {data in
        println(data?[0])
    }

    ack?("Got your event", "dude")
}

socket.on("jsonTest") {data, ack in
    if let json = data?[0] as? NSDictionary {
       println(json["test"]!) // foo bar
    }
}

// Connecting
socket.connect()
```

Objective-C Example
===================
```objective-c
SocketIOClient* socket = [[SocketIOClient alloc] initWithSocketURL:@"localhost:8080" options:nil];

[socket on: @"connect" callback: ^(NSArray* data, void (^ack)(NSArray*)) {
    NSLog(@"connected");
    [socket emitObjc:@"echo" :@[@"echo test"]];
    [[socket emitWithAckObjc:@"ackack" :@[@"test"]] onAck:0 withCallback:^(NSArray* data) {
        NSLog(@"Got data");
    }];
}];

```

Detailed Example
================
A more detailed example can be found [here](https://github.com/nuclearace/socket.io-client-swift-example)

License
=======
MIT
