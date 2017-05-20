//
//  SocketObjectiveCTest.m
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/25/16.
//
//  Merely tests whether the Objective-C api breaks
//

@import Dispatch;
@import Foundation;
@import XCTest;
@import SocketIO;

@interface SocketObjectiveCTest : XCTestCase

@property SocketIOClient* socket;

@end

@implementation SocketObjectiveCTest

- (void)setUp {
    [super setUp];
    NSURL* url = [[NSURL alloc] initWithString:@"http://localhost"];
    self.socket = [[SocketIOClient alloc] initWithSocketURL:url config:@{@"log": @NO, @"forcePolling": @YES}];
}

- (void)testProperties {
    NSURL* url = nil;
    
    url = self.socket.socketURL;
    self.socket.forceNew = false;
    self.socket.handleQueue = dispatch_get_main_queue();
    self.socket.nsp = @"/objective-c";
    self.socket.reconnects = false;
    self.socket.reconnectWait = 1;
}

- (void)testOnSyntax {
    [self.socket on:@"someCallback" callback:^(NSArray* data, SocketAckEmitter* ack) {
        [ack with:@[@1]];
    }];
}

- (void)testConnectSyntax {
    [self.socket connect];
}

- (void)testConnectTimeoutAfterSyntax {
    [self.socket connectWithTimeoutAfter:1 withHandler: ^() { }];
}

- (void)testDisconnectSyntax {
    [self.socket disconnect];
}

- (void)testLeaveNamespaceSyntax {
    [self.socket leaveNamespace];
}

- (void)testJoinNamespaceSyntax {
    [self.socket joinNamespace:@"/objective-c"];
}

- (void)testOnAnySyntax {
    [self.socket onAny:^(SocketAnyEvent* any) {
        NSString* event = any.event;
        NSArray* data = any.items;
        
        [self.socket emit:event with:data];
    }];
}

- (void)testReconnectSyntax {
    [self.socket reconnect];
}

- (void)testRemoveAllHandlersSyntax {
    [self.socket removeAllHandlers];
}

- (void)testEmitSyntax {
    [self.socket emit:@"testEmit" with:@[@YES]];
}

- (void)testEmitWithAckSyntax {
    [[self.socket emitWithAck:@"testAckEmit" with:@[@YES]] timingOutAfter:0 callback:^(NSArray* data) { }];
}

- (void)testOffSyntax {
    [self.socket off:@"test"];
}

- (void)testSocketManager {
    SocketClientManager* manager = [SocketClientManager sharedManager];
    [manager addSocket:self.socket labeledAs:@"test"];
    [manager removeSocketWithLabel:@"test"];
}

@end
