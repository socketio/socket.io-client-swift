[![Build Status](https://travis-ci.org/socketio/socket.io-client-swift.svg?branch=master)](https://travis-ci.org/socketio/socket.io-client-swift)

# Socket.IO-Client-Swift
Socket.IO-client for iOS/OS X.

## Example
```swift
import SocketIO

let manager = SocketManager(socketURL: URL(string: "http://localhost:8080")!, config: [.log(true), .compress])
let socket = manager.defaultSocket

socket.on(clientEvent: .connect) {data, ack in
    print("socket connected")
}

socket.on("currentAmount") {data, ack in
    guard let cur = data[0] as? Double else { return }
    
    socket.emitWithAck("canUpdate", cur).timingOut(after: 0) {data in
        socket.emit("update", ["amount": cur + 2.50])
    }

    ack.with("Got your currentAmount", "dude")
}

socket.connect()
```

## Objective-C Example
```objective-c
@import SocketIO;

NSURL* url = [[NSURL alloc] initWithString:@"http://localhost:8080"];
SocketManager* manager = [[SocketManager alloc] initWithSocketURL:url config:@{@"log": @YES, @"compress": @YES}];
SocketIOClient* socket = manager.defaultSocket;

[socket on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
    NSLog(@"socket connected");
}];

[socket on:@"currentAmount" callback:^(NSArray* data, SocketAckEmitter* ack) {
    double cur = [[data objectAtIndex:0] floatValue];

    [[socket emitWithAck:@"canUpdate" with:@[@(cur)]] timingOutAfter:0 callback:^(NSArray* data) {
        [socket emit:@"update" with:@[@{@"amount": @(cur + 2.50)}]];
    }];

    [ack with:@[@"Got your currentAmount, ", @"dude"]];
}];

[socket connect];

```

## Combine Support (available: iOS 13.0+ macOS 10.15+ tvOS 13.0+ watchOS 6.0+)

Socket.IO-client adds support for combine framework. 

```swift
import SocketIO

var disposeBag: AnyCancellableDisposeBag = []

let manager = SocketManager(socketURL: URL(string: "http://localhost:8080")!, config: [.log(true), .compress])
let socket = manager.defaultSocket

socket.publisher(on: "message")
		.tryMap { output in
            output.ack.with("Got your message")  
            let data = try JSONSerialization.data(withJSONObject: output.data[0], options: [])
            let message = try self.decoder.decode(RTCMessage.self, from: data) 
            return message
        }.catch { (error) -> AnyPublisher<RTCMessage, HTTPError> in
            return Fail(error: HTTPError.encodingIssue(description: error.localizedDescription)).eraseToAnyPublisher()
        }.sink { (error) in
            print(error) // parse error
        } receiveValue: { (message) in
            print(message) // message received
        }.add(to: &disposeBag)
        
        
socket.publisher(clientEvent: .statusChange)
		.map { output -> ConnectionStatus in
            guard let id = output.data.last as? Int else { return .notConnected }
            return ConnectionStatus(rawValue: id) ?? .notConnected // parsing to local ConnectionStatus Enum
        }
        .sink {[unowned self] (status) in
            
        }.add(to: &disposeBag)
        
        socket.connect()
```


## Features
- Supports socket.io 2.0+ (For socket.io 1.0 use v9.x)
- Supports binary
- Supports Polling and WebSockets
- Supports TLS/SSL
- Can be used from Objective-C

## FAQS
Checkout the [FAQs](https://nuclearace.github.io/Socket.IO-Client-Swift/faq.html) for commonly asked questions.

Checkout the [12to13](https://nuclearace.github.io/Socket.IO-Client-Swift/12to13.html) guide for migrating to v13+ from v12 below.


## Installation
Requires Swift 4/5 and Xcode 10.x

If you need Swift 2.3 use the [swift2.3 tag](https://github.com/socketio/socket.io-client-swift/releases/tag/swift2.3) (Pre-Swift 4 support is no longer maintained)

If you need Swift 3.x use v11.1.3.

### Swift Package Manager
Add the project as a dependency to your Package.swift:
```swift
// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "socket.io-test",
    products: [
        .executable(name: "socket.io-test", targets: ["YourTargetName"])
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", .upToNextMinor(from: "15.0.0"))
    ],
    targets: [
        .target(name: "YourTargetName", dependencies: ["SocketIO"], path: "./Path/To/Your/Sources")
    ]
)
```

Then import `import SocketIO`.

### Carthage
Add this line to your `Cartfile`:
```
github "socketio/socket.io-client-swift" ~> 15.2.0
```

Run `carthage update --platform ios,macosx`.

Add the `Starscream` and `SocketIO` frameworks to your projects and follow the usual Carthage process.

### CocoaPods 1.0.0 or later
Create `Podfile` and add `pod 'Socket.IO-Client-Swift'`:

```ruby
use_frameworks!

target 'YourApp' do
    pod 'Socket.IO-Client-Swift', '~> 15.2.0'
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


# [Docs](https://nuclearace.github.io/Socket.IO-Client-Swift/index.html)

- [Client](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketIOClient.html)
- [Manager](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketManager.html)
- [Engine](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketEngine.html)
- [Options](https://nuclearace.github.io/Socket.IO-Client-Swift/Enums/SocketIOClientOption.html)

## Detailed Example
A more detailed example can be found [here](https://github.com/nuclearace/socket.io-client-swift-example)

An example using the Swift Package Manager can be found [here](https://github.com/nuclearace/socket.io-client-swift-spm-example)

## License
MIT
