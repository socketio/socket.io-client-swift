#Socket.IO-Client-Swift
Socket.IO-client for iOS/OS X.

##Example
```swift
let socket = SocketIOClient(socketURL: "localhost:8080")

socket.on("connect") {data, ack in
    println("socket connected")
}

socket.on("currentAmount") {data, ack in
    if let cur = data?[0] as? Double {
        socket.emitWithAck("canUpdate", cur)(timeout: 0) {data in
            socket.emit("update", ["amount": cur + 2.50])
        }

        ack?("Got your currentAmount", "dude")
    }
}

// Connect
socket.connect()
```

##Objective-C Example
```objective-c
SocketIOClient* socket = [[SocketIOClient alloc] initWithSocketURL:@"localhost:8080" options:nil];

[socket on: @"connect" callback: ^(NSArray* data, void (^ack)(NSArray*)) {
    NSLog(@"connected");
    [socket emitObjc:@"echo" withItems:@[@"echo test"]];
    [socket emitWithAckObjc:@"ackack" withItems:@[@1]](10, ^(NSArray* data) {
        NSLog(@"Got ack");
    });
}];

```

##Features
- Supports socket.io 1.0+
- Supports binary
- Supports Polling and WebSockets
- Supports TLS/SSL
- Can be used from Objective-C

##Installation
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

pod 'Socket.IO-Client-Swift', '~> 1.3.2' # Or latest version
```

Install pods:

```
$ pod install
```

Import in your swift file:

```swift
import Socket_IO_Client_Swift
```

##API
Constructors
-----------
`init(socketURL: String, opts:NSDictionary? = nil)` - Constructs a new client for the given URL. opts can be omitted (will use default values)

`convenience init(socketURL: String, options:NSDictionary?)` - Same as above, but meant for Objective-C. See Objective-C Example.

Options
-------
- `reconnects: Bool` Default is `true`
- `reconnectAttempts: Int` Default is `-1` (infinite tries)
- `reconnectWait: Int` Default is `10`
- `forcePolling: Bool` Default is `false`. `true` forces the client to use xhr-polling.
- `forceWebsockets: Bool` Default is `false`. `true` forces the client to use WebSockets.
- `nsp: String` Default is `"/"`
- `cookies: [NSHTTPCookie]?` An array of NSHTTPCookies. Passed during the handshake. Default is nil.

Methods
-------
1. `on(name:String, callback:((data:NSArray?, ack:AckEmitter?) -> Void))` - Adds a handler for an event. Items are passed by an array. `ack` can be used to send an ack when one is requested. See example.
2. `onAny(callback:((event:String, items:AnyObject?)) -> Void)` - Adds a handler for all events. It will be called on any received event.
3. `emit(event:String, _ items:AnyObject...)` - Sends a message. Can send multiple items.
4. `emitObjc(event:String, withItems items:[AnyObject])` - `emit` for Objective-C
5. `emitWithAck(event:String, _ items:AnyObject...) -> (timeout:UInt64, callback:(NSArray?) -> Void) -> Void` - Sends a message that requests an acknowledgement from the server. Returns a function which you can use to add a handler. See example. Note: The message is not sent until you call the returned function.
6. `emitWithAckObjc(event:String, withItems items:[AnyObject]) -> (UInt64, (NSArray?) -> Void) -> Void` - `emitWithAck` for Objective-C. Note: The message is not sent until you call the returned function.
7. `connect()` - Establishes a connection to the server. A "connect" event is fired upon successful connection.
8. `connectWithParams(params:[String: AnyObject])` - Establishes a connection to the server passing the specified params. A "connect" event is fired upon successful connection.
9. `close(#fast:Bool)` - Closes the socket. Once a socket is closed it should not be reopened. Pass true to fast if you're closing from a background task.

Events
------
1. `connect` - Emitted when on a successful connection.
2. `disconnect` - Emitted when the connection is closed.
3. `error` - Emitted if the websocket encounters an error.
4. `reconnect` - Emitted when the connection is starting to reconnect.
5. `reconnectAttempt` - Emitted when attempting to reconnect.

##Detailed Example
A more detailed example can be found [here](https://github.com/nuclearace/socket.io-client-swift-example)

##License
MIT
