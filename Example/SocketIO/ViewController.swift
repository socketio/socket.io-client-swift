//
//  ViewController.swift
//  SocketIO
//
//  Created by BAN Jun on 2015/03/11.
//  Copyright (c) 2015年 codefirst. All rights reserved.
//

import UIKit
import Socket_IO_Client_Swift

class ViewController: UIViewController {
    let socket = SocketIOClient(socketURL: "http://localhost:3000")

    override func viewDidLoad() {
        super.viewDidLoad()
        
        socket.onAny {println("got event: \($0.event) with items \($0.items)")}
        socket.on("connect") { (data, ack) in
            println("on connect: \(data)")
            self.socket.emit("message", "Hello!")
        }
        socket.on("message") { (data, ack) in
            println("on message: \(data)")
            self.socket.close()
        }
        socket.connect()
    }
}

