function socketCallback(testKey, socket, testCase) {
	return function() {
		testCase.assert.apply(undefined , arguments)
		var emitArguments = testCase.returnData;
		var ack = arguments[arguments.length - 1]
		ack.apply(socket, emitArguments)
	}
}

module.exports.socketCallback = socketCallback
