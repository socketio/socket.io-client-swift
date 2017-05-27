[![Build Status](https://travis-ci.org/socketio/socket.io-client-swift.svg?branch=master)](https://travis-ci.org/socketio/socket.io-client-swift)

# Socket.IO-Client-Swift
Socket.IO-client for iOS/OS X.

## Example
```swift
import SocketIO

let socket = SocketIOClient(socketURL: URL(string: "http://localhost:8080")!, config: [.log(true), .forcePolling(true)])

socket.on(clientEvent: .connect) {data, ack in
    print("socket connected")
}

socket.on("currentAmount") {data, ack in
    if let cur = data[0] as? Double {
        socket.emitWithAck("canUpdate", cur).timingOut(after: 0) {data in
            socket.emit("update", ["amount": cur + 2.50])
        }

        ack.with("Got your currentAmount", "dude")
    }
}

socket.connect()
```

## Objective-C Example
```objective-c
@import SocketIO;
NSURL* url = [[NSURL alloc] initWithString:@"http://localhost:8080"];
SocketIOClient* socket = [[SocketIOClient alloc] initWithSocketURL:url config:@{@"log": @YES, @"forcePolling": @YES}];

[socket on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
    NSLog(@"socket connected");
}];

[socket on:@"currentAmount" callback:^(NSArray* data, SocketAckEmitter* ack) {
    double cur = [[data objectAtIndex:0] floatValue];

    [[socket emitWithAck:@"canUpdate" with:@[@(cur)]] timingOutAfter:0 callback:^(NSArray* data) {
        [socket emit:@"update" withItems:@[@{@"amount": @(cur + 2.50)}]];
    }];

    [ack with:@[@"Got your currentAmount, ", @"dude"]];
}];

[socket connect];

```

## Features
- Supports socket.io 2.0+ (For socket.io 1.0 use v9.x)
- Supports binary
- Supports Polling and WebSockets
- Supports TLS/SSL
- Can be used from Objective-C

## Installation
Requires Swift 3/Xcode 8.x

If you need swift 2.3 use the swift2.3 tag (Pre-Swift 3 support is no longer maintained)

If you need swift 2.2 use 7.x (Pre-Swift 3 support is no longer maintained)

If you need Swift 2.1 use v5.5.0 (Pre-Swift 2.2 support is no longer maintained)

If you need Swift 1.2 use v2.4.5 (Pre-Swift 2 support is no longer maintained)

If you need Swift 1.1 use v1.5.2. (Pre-Swift 1.2 support is no longer maintained)

### Manually (iOS 7+)
1. Copy the Source folder into your Xcode project. (Make sure you add the files to your target(s))
2. If you plan on using this from Objective-C, read [this](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/BuildingCocoaApps/MixandMatch.html) on exposing Swift code to Objective-C.

### Swift Package Manager
Add the project as a dependency to your Package.swift:
```swift
import PackageDescription

let package = Package(
    name: "YourSocketIOProject",
    dependencies: [
        .Package(url: "https://github.com/socketio/socket.io-client-swift", majorVersion: 9)
    ]
)
```

Then import `import SocketIO`.

### Carthage
Add this line to your `Cartfile`:
```
github "socketio/socket.io-client-swift" ~> 10.0.0 # Or latest version
```

Run `carthage update --platform ios,macosx`.

### CocoaPods 1.0.0 or later
Create `Podfile` and add `pod 'Socket.IO-Client-Swift'`:

```ruby
use_frameworks!

target 'YourApp' do
    pod 'Socket.IO-Client-Swift', '~> 10.0.0' # Or latest version
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

### CocoaSeeds

Add this line to your `Seedfile`:

```
github "socketio/socket.io-client-swift", "v10.0.0", :files => "Source/*.swift" # Or latest version
```

Run `seed install`.


# [Docs](https://nuclearace.github.io/Socket.IO-Client-Swift/index.html)

- [Client](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketIOClient.html)
- [Engine](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketEngine.html)
- [Options](https://nuclearace.github.io/Socket.IO-Client-Swift/Enums/SocketIOClientOption.html)

## Detailed Example
A more detailed example can be found [here](https://github.com/nuclearace/socket.io-client-swift-example)

An example using the Swift Package Manager can be found [here](https://github.com/nuclearace/socket.io-client-swift-spm-example)

## License
MIT
