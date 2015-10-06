var testCases = require("./TestCases.js")

function registerSocketForEvents(ioSocket, socketCallback, testKind) {
	ioSocket.on('connection', function(socket) {
		var testCase;
		for(testKey in testCases) {
			testCase = testCases[testKey]
			socket.on((testKey + testKind), socketCallback(testKey, socket, testCase))
		}
		
		socket.on('error', function(err) {
			console.log(err)
		})
	})
	
	
}

module.exports.register = registerSocketForEvents