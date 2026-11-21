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
class Manager {
    func addHandlers() {
        let manager = SocketManager(socketURL: URL(string: "http://somesocketioserver.com")!)
        
        manager.defaultSocket.on("myEvent") {data, ack in
            print(data)
        }
    }

}
```

This code is **incorrect**, and the event handler will never be called. Because as soon as this method is called `manager`
will be released, along with the socket, and its memory reclaimed.

A correct way would be:

```swift
class Manager {
    let manager = SocketManager(socketURL: URL(string: "http://somesocketioserver.com")!)
    
    func addHandlers() {
        manager.defaultSocket.on("myEvent") {data, ack in
            print(data)
        }
    }
}

```
