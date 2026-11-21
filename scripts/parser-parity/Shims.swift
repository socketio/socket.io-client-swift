import Foundation
public typealias JSON = [String: Any]
public protocol SocketManagerSpec: AnyObject {
    var parserOptions: SocketParserOptions { get }
}
enum DefaultSocketLogger { static let Logger = QuietLogger() }
struct QuietLogger {
    func log(_ text: String, type: String) {}
    func error(_ text: String, type: String) {}
}
final class Parser: SocketManagerSpec, SocketDataBufferable, SocketParsable {
    let parserOptions = SocketParserOptions()
    var waitingPackets = [SocketPacket]()
}
