import Foundation
import XCTest
@testable import SocketIO

final class SocketBoundedBodyLifecycleTest: XCTestCase {
    func testUnregisteredAndRetiredTaskCallbacksAreHarmless() {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://localhost/unused")!
        let task = session.dataTask(with: url)
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 1, textEncodingName: nil)
        var dispositions: [URLSession.ResponseDisposition] = []
        proxy.urlSession(session, dataTask: task, didReceive: response) { dispositions.append($0) }
        proxy.urlSession(session, dataTask: task, didReceive: Data([9]))
        var completions = 0
        proxy.boundBody(of: task, to: 1) { data, _, error in
            completions += 1
            XCTAssertEqual(data, Data([1]))
            XCTAssertNil(error)
        }
        proxy.urlSession(session, dataTask: task, didReceive: Data([1]))
        proxy.urlSession(session, task: task, didCompleteWithError: nil)
        proxy.urlSession(session, dataTask: task, didReceive: Data([2]))
        proxy.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        XCTAssertEqual(dispositions, [.allow])
        XCTAssertEqual(completions, 1)
    }

    func testLateChunksCannotReplaceOverflowOrCompleteTwice() {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://localhost/unused")!)
        var completions = 0
        proxy.boundBody(of: task, to: 2) { data, _, error in
            completions += 1
            XCTAssertNil(data)
            guard let overflow = error as? SocketBufferLimitError else { return XCTFail("Missing overflow") }
            XCTAssertEqual(overflow.limit, 2)
            XCTAssertEqual(overflow.attempted, 3)
        }
        proxy.urlSession(session, dataTask: task, didReceive: Data([1, 2, 3]))
        proxy.urlSession(session, dataTask: task, didReceive: Data([4, 5, 6, 7]))
        proxy.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        proxy.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(completions, 1)
    }
}
