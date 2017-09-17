## How do I connect to my WebSocket server?

This library is **NOT** a WebSockets library. This library is only for servers that implement the socket.io protocol, 
such as [socket.io](https://socket.io/). If you need a plain WebSockets client check out 
[Starscream](https://github.com/daltoniam/Starscream) for Swift and [JetFire](https://github.com/acmacalister/jetfire)
for Objective-C.

## Why isn't my event handler being called?

One of the most common reasons your event might not be called is if the client is released by 
[ARC](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/AutomaticReferenceCounting.html).

Take this code for example:

```swift
class SocketManager {
    func addHandlers() {
        let socket = SocketIOClient(socketURL: URL(string: "http://somesocketioserver.com")!)
        
        socket.on("myEvent") {data, ack in
            print(data)
        }
    }

}
```

This code is **incorrect**, and the event handler will never be called. Because as soon as this method is called `socket`
will be released and its memory reclaimed.

A correct way would be:

```swift
class SocketManager {
    let socket = SocketIOClient(socketURL: URL(string: "http://somesocketioserver.com")!)
    
    func addHandlers() {
        socket.on("myEvent") {data, ack in
            print(data)
        }
    }
}

```

------

Another case where this might happen is if you use namespaces in your socket.io application.

In the JavaScript client a url that looks like `http://somesocketioserver.com/client` would be done with the `nsp` config.

```swift
let socket = SocketIOClient(socketURL: URL(string: "http://somesocketioserver.com")!, config: [.nsp("/client")])
```
