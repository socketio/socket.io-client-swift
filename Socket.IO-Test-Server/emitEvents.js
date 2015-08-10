function socketCallback(testKey, socket, testCase) {
	return function() {
		testCase.assert.apply(undefined , arguments)
		
		var emitArguments = addArrays([testKey + "EmitReturn"], testCase.returnData)
		socket.emit.apply(socket, emitArguments)
	}
}

function addArrays(firstArray, secondArray) {
	var length = secondArray.length
	var i;
	for(i = 0; i < length; i++) {
		firstArray.push(secondArray[i])
	}
	
	return firstArray;
}

module.exports.socketCallback = socketCallback