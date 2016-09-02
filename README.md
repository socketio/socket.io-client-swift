[![Build Status](https://travis-ci.org/socketio/socket.io-client-swift.svg?branch=master)](https://travis-ci.org/socketio/socket.io-client-swift)

#Socket.IO-Client-Swift
Socket.IO-client for iOS/OS X.

##Example
```swift
import SocketIO

let socket = SocketIOClient(socketURL: NSURL(string: "http://localhost:8080")!, config: [.Log(true), .ForcePolling(true)])

socket.on("connect") {data, ack in
    print("socket connected")
}

socket.on("currentAmount") {data, ack in
    if let cur = data[0] as? Double {
        socket.emitWithAck("canUpdate", cur)(timeoutAfter: 0) {data in
            socket.emit("update", ["amount": cur + 2.50])
        }

        ack.with("Got your currentAmount", "dude")
    }
}

socket.connect()
```

##Objective-C Example
```objective-c
@import SocketIO;
NSURL* url = [[NSURL alloc] initWithString:@"http://localhost:8080"];
SocketIOClient* socket = [[SocketIOClient alloc] initWithSocketURL:url config:@{@"log": @YES, @"forcePolling": @YES}];

[socket on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
    NSLog(@"socket connected");
}];

[socket on:@"currentAmount" callback:^(NSArray* data, SocketAckEmitter* ack) {
    double cur = [[data objectAtIndex:0] floatValue];

    [socket emitWithAck:@"canUpdate" withItems:@[@(cur)]](0, ^(NSArray* data) {
        [socket emit:@"update" withItems:@[@{@"amount": @(cur + 2.50)}]];
    });

    [ack with:@[@"Got your currentAmount, ", @"dude"]];
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
Requires Swift 2.2/Xcode 7.3

If you need Swift 2.1/Xcode 7.2 use v5.5.0 (Pre-Swift 2.2 support is no longer maintained)

If you need Swift 1.2/Xcode 6.3/4 use v2.4.5 (Pre-Swift 2 support is no longer maintained)

If you need Swift 1.1/Xcode 6.2 use v1.5.2. (Pre-Swift 1.2 support is no longer maintained)

Manually (iOS 7+)
-----------------
1. Copy the Source folder into your Xcode project. (Make sure you add the files to your target(s))
2. If you plan on using this from Objective-C, read [this](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/BuildingCocoaApps/MixandMatch.html) on exposing Swift code to Objective-C.

Swift Package Manager
---------------------
Add the project as a dependency to your Package.swift:
```swift
import PackageDescription

let package = Package(
    name: "YourSocketIOProject",
    dependencies: [
        .Package(url: "https://github.com/socketio/socket.io-client-swift", majorVersion: 6)
    ]
)
```

Then import `import SocketIOClientSwift`.

Carthage
-----------------
Add this line to your `Cartfile`:
```
github "socketio/socket.io-client-swift" ~> 7.0.3 # Or latest version
```

Run `carthage update --platform ios,macosx`.

CocoaPods 1.0.0 or later
------------------
Create `Podfile` and add `pod 'Socket.IO-Client-Swift'`:

```ruby
use_frameworks!

target 'YourApp' do
    pod 'Socket.IO-Client-Swift', '~> 7.0.3' # Or latest version
end
```

Install pods:

```
$ pod install
```

Import the module:

Swift:
```swift
import SocketIO
```

Objective-C:

```Objective-C
@import SocketIO;
```

CocoaSeeds
-----------------

Add this line to your `Seedfile`:

```
github "socketio/socket.io-client-swift", "v7.0.3", :files => "Source/*.swift" # Or latest version
```

Run `seed install`.


##API
Constructors
-----------
`init(var socketURL: NSURL, config: SocketIOClientConfiguration = [])` - Creates a new SocketIOClient. If your socket.io server is secure, you need to specify `https` in your socketURL.

`convenience init(socketURL: NSURL, options: NSDictionary?)` - Same as above, but meant for Objective-C. See Options on how convert between SocketIOClientOptions and dictionary keys.

Options
-------
All options are a case of SocketIOClientOption. To get the Objective-C Option, convert the name to lowerCamelCase.

```swift
case ConnectParams([String: AnyObject]) // Dictionary whose contents will be passed with the connection.
case Cookies([NSHTTPCookie]) // An array of NSHTTPCookies. Passed during the handshake. Default is nil.
case DoubleEncodeUTF8(Bool) // Whether or not to double encode utf8. If using the node based server this should be true. Default is true.
case ExtraHeaders([String: String]) // Adds custom headers to the initial request. Default is nil.
case ForcePolling(Bool) // `true` forces the client to use xhr-polling. Default is `false`
case ForceNew(Bool) // Will a create a new engine for each connect. Useful if you find a bug in the engine related to reconnects
case ForceWebsockets(Bool) // `true` forces the client to use WebSockets. Default is `false`
case HandleQueue(dispatch_queue_t) // The dispatch queue that handlers are run on. Default is the main queue.
case Log(Bool) // If `true` socket will log debug messages. Default is false.
case Logger(SocketLogger) // Custom logger that conforms to SocketLogger. Will use the default logging otherwise.
case Nsp(String) // The namespace to connect to. Must begin with /. Default is `/`
case Path(String) // If the server uses a custom path. ex: `"/swift/"`. Default is `""`
case Reconnects(Bool) // Whether to reconnect on server lose. Default is `true`
case ReconnectAttempts(Int) // How many times to reconnect. Default is `-1` (infinite tries)
case ReconnectWait(Int) // Amount of time to wait between reconnects. Default is `10`
case SessionDelegate(NSURLSessionDelegate) // Sets an NSURLSessionDelegate for the underlying engine. Useful if you need to handle self-signed certs. Default is nil.
case Secure(Bool) // If the connection should use TLS. Default is false.
case Security(SSLSecurity) // Allows you to set which certs are valid. Useful for SSL pinning.
case SelfSigned(Bool) // Sets WebSocket.selfSignedSSL. Use this if you're using self-signed certs.
case VoipEnabled(Bool) // Only use this option if you're using the client with VoIP services. Changes the way the WebSocket is created. Default is false
```
Methods
-------
1. `on(event: String, callback: NormalCallback) -> NSUUID` - Adds a handler for an event. Items are passed by an array. `ack` can be used to send an ack when one is requested. See example. Returns a unique id for the handler.
2. `once(event: String, callback: NormalCallback) -> NSUUID` - Adds a handler that will only be executed once. Returns a unique id for the handler.
3. `onAny(callback:((event: String, items: AnyObject?)) -> Void)` - Adds a handler for all events. It will be called on any received event.
4. `emit(event: String, _ items: AnyObject...)` - Sends a message. Can send multiple items.
5. `emit(event: String, withItems items: [AnyObject])` - `emit` for Objective-C
6. `emitWithAck(event: String, _ items: AnyObject...) -> (timeoutAfter: UInt64, callback: (NSArray?) -> Void) -> Void` - Sends a message that requests an acknowledgement from the server. Returns a function which you can use to add a handler. See example. Note: The message is not sent until you call the returned function.
7. `emitWithAck(event: String, withItems items: [AnyObject]) -> (UInt64, (NSArray?) -> Void) -> Void` - `emitWithAck` for Objective-C. Note: The message is not sent until you call the returned function.
8. `connect()` - Establishes a connection to the server. A "connect" event is fired upon successful connection.
9. `connect(timeoutAfter timeoutAfter: Int, withTimeoutHandler handler: (() -> Void)?)` - Connect to the server. If it isn't connected after timeoutAfter seconds, the handler is called.
10. `disconnect()` - Closes the socket. Reopening a disconnected socket is not fully tested.
11. `reconnect()` - Causes the client to reconnect to the server.
12. `joinNamespace(namespace: String)` - Causes the client to join namespace. Shouldn't need to be called unless you change namespaces manually.
13. `leaveNamespace()` - Causes the client to leave the nsp and go back to /
14. `off(event: String)` - Removes all event handlers for event.
15. `off(id id: NSUUID)` - Removes the event that corresponds to id.
16. `removeAllHandlers()` - Removes all handlers.

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
