//
//  InitialOptionsTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 18.10.15.
//
//

import XCTest

class InitialOptionsTest: XCTestCase {
    func testValues() {
        let optionReconnects = SocketInitialOptions.Reconnects(true)
        let array = [optionReconnects]
        let optionSet = Set<SocketInitialOptions>(array)
        guard let optionDict = SocketInitialOptions.transformOptionSetIntoDictionary(optionSet) else { return XCTFail() }
        

        if let reconnectValue = optionDict[optionReconnects.toString()] as? Bool {
            XCTAssert(reconnectValue)
        }
        
    }
}
