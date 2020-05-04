import XCTest

import SocketIOTests

var tests = [XCTestCaseEntry]()
tests += SocketIOTests.allTests()
XCTMain(tests)
