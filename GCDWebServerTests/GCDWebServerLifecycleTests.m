#import <XCTest/XCTest.h>

@import GCDWebServer;

@interface GCDWebServerLifecycleDelegate : NSObject <GCDWebServerDelegate>
@property(nonatomic) BOOL didStartCalled;
@property(nonatomic) BOOL didStopCalled;
@property(nonatomic) BOOL didStartOnMainThread;
@property(nonatomic) BOOL didStopOnMainThread;
@property(nonatomic, strong) XCTestExpectation* didStartExpectation;
@property(nonatomic, strong) XCTestExpectation* didStopExpectation;
@end

@implementation GCDWebServerLifecycleDelegate
- (void)webServerDidStart:(GCDWebServer*)server {
  self.didStartCalled = YES;
  self.didStartOnMainThread = [NSThread isMainThread];
  [self.didStartExpectation fulfill];
}
- (void)webServerDidStop:(GCDWebServer*)server {
  self.didStopCalled = YES;
  self.didStopOnMainThread = [NSThread isMainThread];
  [self.didStopExpectation fulfill];
}
@end

@interface GCDWebServerLifecycleTests : XCTestCase
@property(nonatomic, strong) GCDWebServer* server;
@end

@implementation GCDWebServerLifecycleTests

- (void)setUp {
  [super setUp];
  self.server = [[GCDWebServer alloc] init];
}

- (void)tearDown {
  if (self.server.isRunning) {
    [self.server stop];
  }
  self.server = nil;
  [super tearDown];
}

- (NSDictionary*)startOptions {
  return @{
    GCDWebServerOption_Port : @0,
    GCDWebServerOption_BindToLocalhost : @YES,
    // Match the test thread QoS so stop() doesn't wait on lower-QoS source cancel handlers.
    GCDWebServerOption_DispatchQueuePriority : @(QOS_CLASS_USER_INTERACTIVE),
  };
}

- (void)testStartAndStopUpdateRunning {
  XCTAssertFalse(self.server.isRunning);
  XCTAssertTrue([self.server startWithOptions:[self startOptions] error:nil]);
  XCTAssertTrue(self.server.isRunning);
  [self.server stop];
  XCTAssertFalse(self.server.isRunning);
}

- (void)testPortIsAssignedWhenZero {
  XCTAssertTrue([self.server startWithOptions:[self startOptions] error:nil]);
  XCTAssertGreaterThan(self.server.port, (NSUInteger)0);
}

- (void)testServerURLIsValidWhileRunning {
  XCTAssertTrue([self.server startWithOptions:[self startOptions] error:nil]);
  NSURL* url = self.server.serverURL;
  XCTAssertNotNil(url);
  XCTAssertEqual(url.port.unsignedIntegerValue, self.server.port);
  [self.server stop];
  XCTAssertNil(self.server.serverURL);
}

- (void)testDelegateCallbacks {
  GCDWebServerLifecycleDelegate* delegate = [[GCDWebServerLifecycleDelegate alloc] init];
  delegate.didStartExpectation = [self expectationWithDescription:@"didStart"];
  delegate.didStopExpectation = [self expectationWithDescription:@"didStop"];
  self.server.delegate = delegate;

  XCTAssertTrue([self.server startWithOptions:[self startOptions] error:nil]);
  [self.server stop];

  [self waitForExpectations:@[ delegate.didStartExpectation, delegate.didStopExpectation ]
                    timeout:5.0];
  XCTAssertTrue(delegate.didStartCalled);
  XCTAssertTrue(delegate.didStopCalled);
  XCTAssertTrue(delegate.didStartOnMainThread);
  XCTAssertTrue(delegate.didStopOnMainThread);
}

@end
