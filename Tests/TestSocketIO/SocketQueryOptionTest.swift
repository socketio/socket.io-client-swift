//
//  SocketQueryOptionTest.swift
//  Socket.IO-Client-Swift
//
//  Round 2 of the JavaScript-parity port: `socket.io-client/test/socket.ts`
//  "query option". JS reads the parameters written into the server URL
//  (`if (parsed.query && !opts.query) opts.query = parsed.queryKey` in
//  `lib/index.ts`) and lets an explicit `query` option replace them.
//
//  `JSParityE2ETest` asserts the same four titles end to end against the
//  fixture server's `handshake.query`; these cover the URL the engine builds.
//

import XCTest
@testable import SocketIO

final class SocketQueryOptionTest: XCTestCase {
    private func engine(url: String, _ options: SocketIOClientOption...) -> SocketEngine {
        var config: SocketIOClientConfiguration = [.log(false)]
        for option in options { config.insert(option) }

        let url = URL(string: url)!
        let manager = SocketManager(socketURL: url, config: config)

        return SocketEngine(client: manager, url: url, config: config)
    }

    // MARK: socket.ts > query option — "should accept an object (default namespace)"

    func testConnectParamsObjectReachesTheQuery() {
        let engine = self.engine(url: "http://localhost/", .connectParams(["e": "f"]))

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&e=f&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&e=f&EIO=4")
    }

    // MARK: socket.ts > query option — "should accept a query string (default namespace)"

    func testQueryStringInTheServerURLReachesTheQuery() {
        let engine = self.engine(url: "http://localhost/?c=d")

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&c=d&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&c=d&EIO=4")
    }

    // MARK: socket.ts > query option — "should accept a query string" (several parameters)

    func testEveryQueryStringParameterInTheServerURLIsKept() {
        let engine = self.engine(url: "http://localhost/?b=c&d=e")

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&b=c&d=e&EIO=4")
    }

    /// Percent-encoded parameters survive verbatim: re-encoding them would
    /// double-escape the separators.
    func testPercentEncodedQueryStringIsNotDoubleEscaped() {
        let engine = self.engine(url: "http://localhost/?%26a=%26%3D%3Fa")

        XCTAssertEqual(URLComponents(url: engine.urlPolling, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       "transport=polling&b64=1&%26a=%26%3D%3Fa&EIO=4")
    }

    /// JS `if (parsed.query && !opts.query)`: an explicit `query` replaces the
    /// URL's parameters instead of merging with them.
    func testConnectParamsReplaceTheURLQuery() {
        let engine = self.engine(url: "http://localhost/?c=d", .connectParams(["e": "f"]))

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&e=f&EIO=4")
    }

    /// An explicit empty query is truthy in JS and replaces the URL query.
    func testEmptyConnectParamsReplaceTheURLQuery() {
        let engine = self.engine(url: "http://localhost/?c=d", .connectParams([:]))

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&EIO=4")
    }

    func testNoQueryAnywhereLeavesTheEngineParametersAlone() {
        let engine = self.engine(url: "http://localhost/")

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&EIO=4")
    }
}
