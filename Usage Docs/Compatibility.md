Here is the compatibility table with the Node.js server:

<table>
    <tr>
        <th rowspan="2">Swift Client version</th>
        <th colspan="3">Socket.IO server version</th>
    </tr>
    <tr>
        <td align="center">2.x</td>
        <td align="center">3.x</td>
        <td align="center">4.x</td>
    </tr>
    <tr>
        <td align="center">v15.x</td>
        <td align="center"><b>YES</b></td>
        <td align="center"><b>YES</b><sup>1</sup></td>
        <td align="center"><b>YES</b><sup>2</sup></td>
    </tr>
    <tr>
        <td align="center">v16.x</td>
        <td align="center"><b>YES</b><sup>3</sup></td>
        <td align="center"><b>YES</b></td>
        <td align="center"><b>YES</b></td>
    </tr>
</table>

[1] Yes, with <code><a href="https://socket.io/docs/v4/server-initialization/#allowEIO3">allowEIO3: true</a></code> (server) and `.connectParams(["EIO": "3"])` (client):

*Server*

```js
const { createServer } = require("http");
const { Server } = require("socket.io");

const httpServer = createServer();
const io = new Server(httpServer, {
  allowEIO3: true
});

httpServer.listen(8080);
```

*Client*

```swift
SocketManager(socketURL: URL(string:"http://localhost:8080/")!, config: [.connectParams(["EIO": "3"])])
```

[2] Yes, <code><a href="https://socket.io/docs/v4/server-initialization/#allowEIO3">allowEIO3: true</a></code> (server)

[3] Yes, with `.version(.two)` (client):

```swift
SocketManager(socketURL: URL(string:"http://localhost:8080/")!, config: [.version(.two)])
```

See also:

- Migrating from 2.x to 3.0: https://socket.io/docs/v4/migrating-from-2-x-to-3-0/
- Migrating from 3.x to 4.0: https://socket.io/docs/v4/migrating-from-3-x-to-4-0/
- Socket.IO protocol: https://github.com/socketio/socket.io-protocol
