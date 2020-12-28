//
//  DisposeBag.swift
//  Socket.IO-Client-Swift
//
//  Created by Zahid on 28/12/2020.
//

import Foundation
import Combine

public typealias AnyCancellableDisposeBag = [AnyCancellable]

// MARK: - AnyCancellable+DisposeBag
/// Adds dispose functionality to `AnyCancellable` class can be can be used to store subscriber tokens.
extension AnyCancellable {
    
    /// Add `AnyCancellable` to dispose bag
    /// - Parameter bag: `inout` bag for disposal
    public func add(to bag:inout AnyCancellableDisposeBag) -> Void {
        bag.append(self)
    }
    
}
