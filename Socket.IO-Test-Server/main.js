var app = require('express')()
var server = app.listen(6979)
var io = require('socket.io')(server)
var acknowledgementsEvents = require("./acknowledgementEvents.js")
var emitEvents = require("./emitEvents.js")
var socketEventRegister = require("./socketEventRegister.js")

socketEventRegister.register(io, emitEvents.socketCallback, "Emit")
socketEventRegister.register(io, acknowledgementsEvents.socketCallback, "Acknowledgement")

var nsp = io.of("/swift")
socketEventRegister.register(nsp, emitEvents.socketCallback, "Emit")
socketEventRegister.register(nsp, acknowledgementsEvents.socketCallback, "Acknowledgement")
