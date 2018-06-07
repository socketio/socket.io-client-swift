//
// Created by Erik Little on 10/21/17.
//

#import "ManagerObjectiveCTest.h"

@import Dispatch;
@import Foundation;
@import XCTest;
@import SocketIO;

@implementation ManagerObjectiveCTest

- (void)testSettingConfig {
    NSURL* url = [[NSURL alloc] initWithString:@"http://localhost"];
    NSDictionary* headers = @{@"My Header": @"Some Value"};

    self.manager = [[TestManager alloc] initWithSocketURL:url config:@{
            @"forceNew": @YES,
            @"extraHeaders": headers
    }];

    [self.manager connect];

    XCTAssertTrue(self.manager.forceNew);
    XCTAssertTrue([self.manager.engine.extraHeaders isEqualToDictionary:headers]);

}

- (void)testManagerProperties {
    XCTAssertNotNil(self.manager.defaultSocket);
    XCTAssertNil(self.manager.engine);
    XCTAssertFalse(self.manager.forceNew);
    XCTAssertEqual(self.manager.handleQueue, dispatch_get_main_queue());
    XCTAssertTrue(self.manager.reconnects);
    XCTAssertEqual(self.manager.reconnectWait, 10);
    XCTAssertEqual(self.manager.status, SocketIOStatusNotConnected);
}

- (void)testConnectSocketSyntax {
    [self setUpSockets];
    [self.manager connectSocket:self.socket];
}

- (void)testDisconnectSocketSyntax {
    [self setUpSockets];
    [self.manager disconnectSocket:self.socket];
}

- (void)testSocketForNamespaceSyntax {
    SocketIOClient* client = [self.manager socketForNamespace:@"/swift"];
    client = nil;
}

- (void)testManagerCallsConnect {
    [self setUpSockets];

    XCTestExpectation* expect = [self expectationWithDescription:@"The manager should call connect on the default socket"];
    XCTestExpectation* expect2 = [self expectationWithDescription:@"The manager should call connect on the socket"];

    self.socket.expects[@"didConnectCalled"] = expect;
    self.socket2.expects[@"didConnectCalled"] = expect2;

    [self.socket connect];
    [self.socket2 connect];

    [self.manager fakeConnecting];
    [self.manager fakeConnectingToNamespace:@"/swift"];

    [self waitForExpectationsWithTimeout:0.3 handler:nil];
}

- (void)testManagerCallsDisconnect {
    [self setUpSockets];

    XCTestExpectation* expect = [self expectationWithDescription:@"The manager should call disconnect on the default socket"];
    XCTestExpectation* expect2 = [self expectationWithDescription:@"The manager should call disconnect on the socket"];

    self.socket.expects[@"didDisconnectCalled"] = expect;
    self.socket2.expects[@"didDisconnectCalled"] = expect2;

    [self.socket2 on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
        [self.manager disconnect];
        [self.manager fakeDisconnecting];
    }];

    [self.socket connect];
    [self.socket2 connect];

    [self.manager fakeConnecting];
    [self.manager fakeConnectingToNamespace:@"/swift"];

    [self waitForExpectationsWithTimeout:0.3 handler:nil];
}

- (void)testManagerEmitAll {
    [self setUpSockets];

    XCTestExpectation* expect = [self expectationWithDescription:@"The manager should emit an event to the default socket"];
    XCTestExpectation* expect2 = [self expectationWithDescription:@"The manager should emit an event to the socket"];

    self.socket.expects[@"emitAllEventCalled"] = expect;
    self.socket2.expects[@"emitAllEventCalled"] = expect2;

    [self.socket2 on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
        [self.manager emitAll:@"event" withItems:@[@"testing"]];
    }];

    [self.socket connect];
    [self.socket2 connect];

    [self.manager fakeConnecting];
    [self.manager fakeConnectingToNamespace:@"/swift"];

    [self waitForExpectationsWithTimeout:0.3 handler:nil];
}

- (void)testMangerRemoveSocket {
    [self setUpSockets];

    [self.manager removeSocket:self.socket];

    XCTAssertNil(self.manager.nsps[self.socket.nsp]);
}

- (void)setUpSockets {
    self.socket = [self.manager testSocketForNamespace:@"/"];
    self.socket2 = [self.manager testSocketForNamespace:@"/swift"];
}

- (void)setUp {
    [super setUp];
    NSURL* url = [[NSURL alloc] initWithString:@"http://localhost"];
    self.manager = [[TestManager alloc] initWithSocketURL:url config:@{@"log": @NO}];
    self.socket = nil;
    self.socket2 = nil;
}

@end
