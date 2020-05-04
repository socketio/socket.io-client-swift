import XCTest
@testable import SocketIO

final class SocketIOTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(SocketIO().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
