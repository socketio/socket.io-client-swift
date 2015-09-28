//
//  SocketPollingNamespaceAcknowledgementTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 9/28/15.
//
//

import Foundation
import XCTest

class SocketPollingNamespaceAcknowledgementTest: SocketNamespaceAcknowledgementTest {
    override func setUp() {
        AbstractSocketTest.socket = AbstractSocketTest.namespacePollingSocket
        testKind = .Acknowledgement
    }
}