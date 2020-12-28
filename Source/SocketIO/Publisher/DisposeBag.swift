//
//  DisposeBag.swift
//  Socket.IO-Client-Swift
//
//  Created by Zahid on 28/12/2020.
//

import Foundation
import Combine

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public typealias AnyCancellableDisposeBag = [AnyCancellable]

// MARK: - AnyCancellable+DisposeBag
/// Adds dispose functionality to `AnyCancellable` class can be can be used to store subscriber tokens.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension AnyCancellable {
    
    /// Add `AnyCancellable` to dispose bag
    /// - Parameter bag: `inout` bag for disposal
    public func add(to bag:inout AnyCancellableDisposeBag) -> Void {
        bag.append(self)
    }
    
}
