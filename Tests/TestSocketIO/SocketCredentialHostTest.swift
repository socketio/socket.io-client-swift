import XCTest
@testable import SocketIO

final class SocketCredentialHostTest: XCTestCase {
    func testEquivalentDNSHostSpellingsMatchInBothDirections() {
        for (first, second) in [
            ("localhost", "LOCALHOST"),
            ("example.test", "example.test."),
            ("bücher.example", "xn--bcher-kva.example"),
            ("BÜCHER.example.", "xn--bcher-kva.example"),
            ("bu\u{0308}cher.example", "xn--bcher-kva.example."),
            ("bücher.example。", "xn--bcher-kva.example"),
            ("127.0.0.1", "127.0.0.1"),
            ("[2001:DB8::1]", "2001:db8::1"),
            ("[::1]", "0:0:0:0:0:0:0:1"),
            ("[fe80::1%en0]", "fe80::1%en0")
        ] {
            XCTAssertTrue(SocketCredentialHost.matches(first, second), "\(first) / \(second)")
            XCTAssertTrue(SocketCredentialHost.matches(second, first), "\(second) / \(first)")
        }
    }

    func testDifferentHostsStayDifferent() {
        for (first, second) in [
            ("example.test", "other.test"),
            ("example.test", "sub.example.test"),
            ("example.test", "example.test.evil"),
            ("example.test", "exаmple.test"), // Cyrillic 'а'.
            ("bücher.example", "bucher.example"),
            ("bücher.example", "xn--bcher-kva.example.evil"),
            ("[::1]", "[::2]"),
            ("fe80::1%en0", "fe80::1%en1"),
            ("fe80::1%en0", "fe80::1%EN0"),
            ("fe80::1%en0", "fe80::1")
        ] {
            XCTAssertFalse(SocketCredentialHost.matches(first, second), "\(first) / \(second)")
        }
    }

    func testInvalidHostsNeverMatchEvenThemselves() {
        XCTAssertFalse(SocketCredentialHost.matches(nil, "example.test"))
        for host in ["", ".", "example.test..", ".example.test", "example..test",
                     "-example.test", "example-.test", "example.test/", "example.test@evil.test",
                     "example.test?x", "example.test#x", "example%2etest", " example.test",
                     "example.test\n", "example\u{0000}.test", "example.test\\evil",
                     "[example.test]", "[foo:bar]", "[dead:beef]", "[::1", "[::1]:443", "example.test:443",
                     "fe80::1%", "fe80::1%en0%extra", "[::1]/evil",
                     String(repeating: "a", count: 64) + ".test"] {
            XCTAssertFalse(SocketCredentialHost.matches(host, host), host)
            XCTAssertFalse(SocketCredentialHost.matches("example.test", host), host)
        }
    }
}
