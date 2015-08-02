var assert = require("assert")

module.exports = {
	basicTest: {
		assert: function(inputData) {
			
		},
		returnData: []
	}, 
	testNull: {
		assert: function(inputData) {
			assert(!inputData)
		},
		returnData: [null]
	},
	testBinary: {
		assert: function(inputData) {
			 assert.equal(inputData.toString(), "gakgakgak2")
		},
		returnData: [new Buffer("gakgakgak2", "utf-8")]
	},
	testArray: {
		assert: function(inputData) {
			assert.equal(inputData.length, 2)
		    assert.equal(inputData[0], "test1")
		    assert.equal(inputData[1], "test2")
		},
		returnData: [["test3", "test4"]]
	},
	testString: {
		assert: function(inputData) {
			assert.equal(inputData, "marco")
		},
		returnData: ["polo"]
	},
	testBool: {
		assert: function(inputData) {
			assert(!inputData)
		},
		returnData: [true]
	},
	testInteger: {
		assert: function(inputData) {
			assert.equal(inputData, 10)
		},
		returnData: [20]
	},
	testDouble: {
		assert: function(inputData) {
			 assert.equal(inputData, 1.1)
		},
		returnData: [1.2]
	},
	testJSON: {
		assert: function(inputData) {
			assert.equal(inputData.name, "test")
		    assert.equal(inputData.nestedTest.test, "test")
		    assert.equal(inputData.testArray.length, 1)
		},
		returnData: [{testString: "test", testNumber: 15, nestedTest: {test: "test"}, testArray: [1, 1]}]
	},	
	testJSONWithBuffer: {
		assert: function(inputData) {
			assert.equal(inputData.name, "test")
		    assert.equal(inputData.nestedTest.test, "test")
		    assert.equal(inputData.testArray.length, 1)
		},
		returnData: [{testString: "test", testNumber: 15, nestedTest: {test: "test"}, testArray: [new Buffer("gakgakgak2", "utf-8"), 1]}]
	},testUnicode: {
		assert: function(inputData) {
			assert.equal(inputData, "🚀")
		},
		returnData: ["🚄"]
	},testMultipleItems: {
		assert: function(array, object, number, string, bool) {
			assert.equal(array.length, 2)
			assert.equal(array[0], "test1")
			assert.equal(array[1], "test2")
			assert.equal(number, 15)
			assert.equal(string, "marco")
			assert.equal(bool, false)	
		},
		returnData: [[1, 2], {test: "bob"}, 25, "polo", false]
	},testMultipleItemsWithBuffer: {
		assert: function(array, object, number, string, binary) {
			assert.equal(array.length, 2)
			assert.equal(array[0], "test1")
			assert.equal(array[1], "test2")
			assert.equal(number, 15)
			assert.equal(string, "marco")
			assert.equal(binary.toString(), "gakgakgak2")
		},
		returnData: [[1, 2], {test: "bob"}, 25, "polo", new Buffer("gakgakgak2")]
	}
}