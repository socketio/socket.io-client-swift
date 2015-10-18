//
//  InitialOptions.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 17.10.15.
//
//

import Foundation

enum SocketInitialOptions: Hashable, Equatable {
    case ConnectionParameter([String: AnyObject])
    case Reconnects(Bool)
    
    var hashValue: Int {
        switch self {
        case .Reconnects:
            return 0
        case .ConnectionParameter:
            return 1
        }
    }
    
    
    
    var value: NSObject {
        switch self {
        case .Reconnects(let reconnects):
            return reconnects
        case .ConnectionParameter(let parameters):
            return parameters
        }
    }

    func toString() -> String {
        switch self {
        case ConnectionParameter:
            return "connectParams"
        case Reconnects:
            return "reconnects"
        }
    }
    
    static func transformOptionSetIntoDictionary(options: Set<SocketInitialOptions>?) ->[String: AnyObject]? {
        guard let options = options else { return nil }
        var dictionary = [String: AnyObject]()
        for (_, option) in options.enumerate() {
            dictionary.updateValue(option.value, forKey: option.toString())
        }
        return dictionary
    }
}


func ==(lhs: SocketInitialOptions, rhs: SocketInitialOptions) -> Bool {
    return lhs.hashValue == rhs.hashValue
}

