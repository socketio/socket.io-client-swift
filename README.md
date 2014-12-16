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

socket.on("foobar") {data in
    if let json = socket.toJSON(data) {
        println(json["test"])
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
    var err:NSError?
    var stringData = data as String
    var data = stringData.dataUsingEncoding(NSUTF8StringEncoding)
    var json = NSJSONSerialization.JSONObjectWithData(data!, 
        options: NSJSONReadingOptions.AllowFragments, error: &err) as NSDictionary
    var bufData = NSData(base64EncodedString: (json["buf"] as String),
        options: NSDataBase64DecodingOptions.allZeros)
    if let dataAsString = NSString(data: bufData!, encoding: NSUTF8StringEncoding) {
        println(dataAsString)
    }
}

```
