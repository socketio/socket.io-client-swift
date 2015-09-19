var app = require('http').createServer()
var io = require('socket.io')(app);
app.listen(6979)


var acknowledgementsEvents = require("./acknowledgementEvents.js")
var emitEvents = require("./emitEvents.js")
var socketEventRegister = require("./socketEventRegister.js")

socketEventRegister.register(io, emitEvents.socketCallback, "Emit")
socketEventRegister.register(io, acknowledgementsEvents.socketCallback, "Acknowledgement")

var nsp = io.of("/swift")
socketEventRegister.register(nsp, emitEvents.socketCallback, "Emit")
socketEventRegister.register(nsp, acknowledgementsEvents.socketCallback, "Acknowledgement")
