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

socket.connect()
```

##Objective-C Example
```objective-c
SocketIOClient* socket = [[SocketIOClient alloc] initWithSocketURL:@"localhost:8080" options:nil];

[socket on:@"connect" callback:^(NSArray* data, void (^ack)(NSArray*)) {
    NSLog(@"socket connected");
}];

[socket on:@"currentAmount" callback:^(NSArray* data, void (^ack)(NSArray*)) {
    double cur = [[data objectAtIndex:0] floatValue];

    [socket emitWithAck:@"canUpdate" withItems:@[@(cur)]](0, ^(NSArray* data) {
        [socket emit:@"update" withItems:@[@{@"amount": @(cur + 2.50)}]];
    });

    ack(@[@"Got your currentAmount, ", @"dude"]);
}];

[socket connect];

```

##Features
- Supports socket.io 1.0+
- Supports binary
- Supports Polling and WebSockets
- Supports TLS/SSL
- Can be used from Objective-C

##Installation
Requires Swift 1.2/Xcode 6.3

If you need Swift 1.1/Xcode 6.2 use v1.5.2. (Pre-Swift 1.2 support is no longer maintained)
Manually (iOS 7+)
-----------------
1. Copy the SocketIOClientSwift folder into your Xcode project. (Make sure you add the files to your target(s))
2. If you plan on using this from Objective-C, read [this](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/BuildingCocoaApps/MixandMatch.html) on exposing Swift code to Objective-C.

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
- `connectParams: [String: AnyObject]?` - Dictionary whose contents will be passed with the connection.
- `reconnects: Bool` Default is `true`
- `reconnectAttempts: Int` Default is `-1` (infinite tries)
- `reconnectWait: Int` Default is `10`
- `forcePolling: Bool` Default is `false`. `true` forces the client to use xhr-polling.
- `forceWebsockets: Bool` Default is `false`. `true` forces the client to use WebSockets.
- `nsp: String` Default is `"/"`. Connects to a namespace.
- `cookies: [NSHTTPCookie]?` An array of NSHTTPCookies. Passed during the handshake. Default is nil.
- `log: Bool` If `true` socket will log debug messages. Default is false.
- `sessionDelegate: NSURLSessionDelegate` Sets an NSURLSessionDelegate for the underlying engine. Useful if you need to handle self-signed certs. Default is nil.
- `path: String` - If the server uses a custom path. ex: `"/swift"`. Default is `""`

Methods
-------
1. `on(name:String, callback:((data:NSArray?, ack:AckEmitter?) -> Void))` - Adds a handler for an event. Items are passed by an array. `ack` can be used to send an ack when one is requested. See example.
2. `onAny(callback:((event:String, items:AnyObject?)) -> Void)` - Adds a handler for all events. It will be called on any received event.
3. `emit(event:String, _ items:AnyObject...)` - Sends a message. Can send multiple items.
4. `emit(event:String, withItems items:[AnyObject])` - `emit` for Objective-C
5. `emitWithAck(event:String, _ items:AnyObject...) -> (timeout:UInt64, callback:(NSArray?) -> Void) -> Void` - Sends a message that requests an acknowledgement from the server. Returns a function which you can use to add a handler. See example. Note: The message is not sent until you call the returned function.
6. `emitWithAck(event:String, withItems items:[AnyObject]) -> (UInt64, (NSArray?) -> Void) -> Void` - `emitWithAck` for Objective-C. Note: The message is not sent until you call the returned function.
7. `connect()` - Establishes a connection to the server. A "connect" event is fired upon successful connection.
8. `connect(#timeoutAfter:Int, withTimeoutHandler handler:(() -> Void)?)` - Connect to the server. If it isn't connected after timeoutAfter seconds, the handler is called.
9. `close(#fast:Bool)` - Closes the socket. Once a socket is closed it should not be reopened. Pass true to fast if you're closing from a background task.
10. `reconnect()` - Causes the client to reconnect to the server.
11. `joinNamespace()` - Causes the client to join nsp. Shouldn't need to be called unless you change nsp manually.
12. `leaveNamespace()` - Causes the client to leave the nsp and go back to /

Client Events
------
1. `connect` - Emitted when on a successful connection.
2. `disconnect` - Emitted when the connection is closed.
3. `error` - Emitted on an error.
4. `reconnect` - Emitted when the connection is starting to reconnect.
5. `reconnectAttempt` - Emitted when attempting to reconnect.

##Detailed Example
A more detailed example can be found [here](https://github.com/nuclearace/socket.io-client-swift-example)

##License
MIT
