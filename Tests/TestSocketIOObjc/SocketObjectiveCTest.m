//
//  SocketObjectiveCTest.m
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/25/16.
//
//  Merely tests whether the Objective-C api breaks
//

#import "SocketIO_Tests-Swift.h"
#import "SocketObjectiveCTest.h"

@import Dispatch;
@import Foundation;
@import XCTest;
@import SocketIO;

// TODO Manager interface tests

@implementation SocketObjectiveCTest

- (void)testProperties {
    XCTAssertTrue([self.socket.nsp isEqualToString:@"/"]);
    XCTAssertEqual(self.socket.status, SocketIOStatusNotConnected);
}

- (void)testOnSyntax {
    [self.socket on:@"someCallback" callback:^(NSArray* data, SocketAckEmitter* ack) {
        [ack with:@[@1]];
        [[ack rawEmitView] with:@[@"hello"]];
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
    [self.socket joinNamespace];
}

- (void)testOnAnySyntax {
    [self.socket onAny:^(SocketAnyEvent* any) {
        NSString* event = any.event;
        NSArray* data = any.items;

        [self.socket emit:event with:data];
    }];
}

- (void)testRemoveAllHandlersSyntax {
    [self.socket removeAllHandlers];
}

- (void)testEmitSyntax {
    [self.socket emit:@"testEmit" with:@[@YES]];
}

- (void)testEmitWriteCompletionSyntax {
    [self.socket emit:@"testEmit" with:@[@YES] completion:^{}];
}

- (void)testEmitWriteCompletion {
    XCTestExpectation* expect = [self expectationWithDescription:@"Write completion should be called"];

    [self.socket emit:@"testEmit" with:@[@YES] completion:^{
        [expect fulfill];
    }];

    [self waitForExpectationsWithTimeout:0.3 handler:nil];
}

- (void)testRawEmitSyntax {
    [[self.socket rawEmitView] emit:@"myEvent" with:@[@1]];
}

- (void)testEmitWithAckSyntax {
    [[self.socket emitWithAck:@"testAckEmit" with:@[@YES]] timingOutAfter:0 callback:^(NSArray* data) { }];
}

- (void)testOffSyntax {
    [self.socket off:@"test"];
}

- (void)testSSLSecurity {
    SSLSecurity* sec = [[SSLSecurity alloc] initWithUsePublicKeys:0];
    sec = nil;
}

- (void)testStatusChangeHandler {
    XCTestExpectation* expect = [self expectationWithDescription:@"statusChange should be correctly called"];

    [self.socket on:@"statusChange" callback:^(NSArray* data, SocketAckEmitter* ack) {
        XCTAssertTrue([data[1] integerValue] == SocketIOStatusConnecting);
        [expect fulfill];
    }];

    [OBjcUtils setTestStatusWithSocket:self.socket status:SocketIOStatusConnecting];

    [self waitForExpectationsWithTimeout:0.3 handler:nil];
}

- (void)setUp {
    [super setUp];
    NSURL* url = [[NSURL alloc] initWithString:@"http://localhost"];
    self.manager = [[SocketManager alloc] initWithSocketURL:url config:@{@"log": @NO}];
    self.socket = [self.manager defaultSocket];
}

@end
