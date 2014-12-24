Socket.IO-Client-Swift
======================

Socket.IO-client for Swift. Supports ws/wss connections and binary

Installation
============
1. Requires linking [SocketRocket](https://github.com/square/SocketRocket) against your xcode project. (Be sure to link the frameworks required by SocketRocket)
2. Create a bridging header for SocketRocket
3. Copy the SwiftIO folder into your xcode project

Use
===

```swift
// opts can be omitted, will use default values
let socket = SocketIOClient(socketURL: "https://localhost:8080", opts: [
    "reconnects": true, // default true
    "reconnectAttempts": 5, // default 10
    "reconnectWait": 5 // default 10
])

socket.on("connect") {data in
    println("socket connected")
    socket.emit("testEcho")
    socket.emit("testObject", args: [
        "data": true
        ])
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

socket.on("jsonTest") {data in
    if let json = data as? NSDictionary {
       println(json["test"]!) // foo bar
    }
}

socket.on("boolTest") {data in
    if let bool = data as? Bool {
        println(bool) // true
    }
}

socket.on("arrayTest") {data in
    if let array = data as? NSArray {
        println(array[0]) // 2
        println(array[1]) // "test"
    }
}

socket.on("intTest") {data in
    if let intData = data as? Int {
        println(intData)
    }
}
socket.connect()
```

Binary support is not guaranteed to work. All recieved data is encoded in base64 strings.
```swift
// Sending binary
socket.emit("testObject", args: [
        "data": "Hello World".dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!,
        "test": true])
        
// Recieving data
socket.on("dataTest") {data in
    if let json = data as? NSDictionary {
        var textData = NSData(base64EncodedString: (json["test"] as String),
            options: NSDataBase64DecodingOptions.IgnoreUnknownCharacters)
        if let dataAsString = NSString(data: textData!, encoding: NSUTF8StringEncoding) {
            println(dataAsString)
        }
    }
}
```
