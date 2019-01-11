//
// Created by Erik Little on 2019-01-11.
//

import Foundation
@testable import SocketIO

public class OBjcUtils: NSObject {
    @objc
    public static func setTestStatus(socket: SocketIOClient, status: SocketIOStatus) {
        socket.setTestStatus(status)
    }
}
