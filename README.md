Socket.IO-Client-Swift
======================

Work in progress

socket.io-client for Swift

Installation
============
1. Requires linking [SocketRocket](https://github.com/square/SocketRocket) against your xcode project.
2. Create a bridging header for SocketRocket
3. Copy the SwiftIO folder into your xcode project

Use
===

```
let socket = SocketIOClient(socketURL: "http://localhost:8080")
// let socket = SocketIOClient(socketURL: "https://localhost:8080", secure: true)
socket.on("connect") {data in
    println("socket connected")
    socket.emit("testEcho")
    socket.emit("testObject", args: [
        "data": true
        ])
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
    if let array = data as? [Any] {
        println(array[0]) // 2
        println(array[1]) // "test"
    }
}

socket.on("intTest") {data in
    if let stringData = data as? NSString {
        println(stringData.integerValue)
    }
}
socket.connect()
```

Binary support is not guaranteed to work. All recieved data is encoded in base64 strings.
```
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
