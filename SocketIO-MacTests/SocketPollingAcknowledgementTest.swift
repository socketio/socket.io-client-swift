//
//  SocketPollingAcknowledgementTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 9/28/15.
//
//

import Foundation
import XCTest

class SocketPollingAcknowledgementTest: SocketAcknowledgementTest {
    override func setUp() {
        AbstractSocketTest.socket = AbstractSocketTest.regularPollingSocket
        testKind = .Acknowledgement
    }
}
