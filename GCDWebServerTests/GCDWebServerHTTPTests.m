#import <XCTest/XCTest.h>

@import GCDWebServer;

@interface GCDWebServerHTTPTests : XCTestCase
@property(nonatomic, strong) GCDWebServer* server;
@property(nonatomic, strong) NSURL* baseURL;
@property(nonatomic, strong) NSMutableArray<NSString*>* tempPaths;
@end

@implementation GCDWebServerHTTPTests

- (void)setUp {
  [super setUp];
  self.server = [[GCDWebServer alloc] init];
  self.tempPaths = [NSMutableArray array];
}

- (void)tearDown {
  if (self.server.isRunning) {
    [self.server stop];
  }
  self.server = nil;
  self.baseURL = nil;
  NSFileManager* fm = [NSFileManager defaultManager];
  for (NSString* path in self.tempPaths) {
    [fm removeItemAtPath:path error:nil];
  }
  self.tempPaths = nil;
  [super tearDown];
}

#pragma mark - Helpers

- (void)startServer {
  [self startServerWithExtraOptions:nil];
}

- (void)startServerWithExtraOptions:(NSDictionary*)extra {
  NSMutableDictionary* options = [NSMutableDictionary dictionaryWithDictionary:@{
    GCDWebServerOption_Port : @0,
    GCDWebServerOption_BindToLocalhost : @YES,
    // Match the test thread QoS so stop() doesn't wait on lower-QoS source cancel handlers.
    GCDWebServerOption_DispatchQueuePriority : @(QOS_CLASS_USER_INTERACTIVE),
  }];
  if (extra) {
    [options addEntriesFromDictionary:extra];
  }
  NSError* error = nil;
  BOOL ok = [self.server startWithOptions:options error:&error];
  XCTAssertTrue(ok, @"Server failed to start: %@", error);
  XCTAssertGreaterThan(self.server.port, (NSUInteger)0);
  self.baseURL = self.server.serverURL;
  XCTAssertNotNil(self.baseURL);
}

- (NSURL*)urlForPath:(NSString*)path {
  return [NSURL URLWithString:path relativeToURL:self.baseURL];
}

- (void)performRequest:(NSURLRequest*)request
              response:(NSHTTPURLResponse* _Nullable __autoreleasing* _Nullable)outResponse
                  body:(NSData* _Nullable __autoreleasing* _Nullable)outBody {
  XCTestExpectation* expectation = [self expectationWithDescription:@"http"];
  __block NSHTTPURLResponse* response = nil;
  __block NSData* body = nil;
  NSURLSessionDataTask* task =
      [[NSURLSession sharedSession] dataTaskWithRequest:request
                                      completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
                                        XCTAssertNil(err, @"URL request failed: %@", err);
                                        response = (NSHTTPURLResponse*)resp;
                                        body = data;
                                        [expectation fulfill];
                                      }];
  [task resume];
  [self waitForExpectations:@[ expectation ] timeout:10.0];
  if (outResponse) *outResponse = response;
  if (outBody) *outBody = body;
}

- (NSString*)writeTempFileWithContents:(NSData*)data extension:(NSString*)ext {
  NSString* name = [[[NSUUID UUID] UUIDString] stringByAppendingPathExtension:ext];
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  XCTAssertTrue([data writeToFile:path atomically:YES]);
  [self.tempPaths addObject:path];
  return path;
}

- (NSString*)makeTempDirectory {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:path
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:nil]);
  [self.tempPaths addObject:path];
  return path;
}

#pragma mark - Tests

- (void)testGETStaticData {
  NSData* payload = [@"hello world" dataUsingEncoding:NSUTF8StringEncoding];
  [self.server addGETHandlerForPath:@"/hello"
                         staticData:payload
                        contentType:@"text/plain"
                           cacheAge:0];
  [self startServer];

  NSURLRequest* req = [NSURLRequest requestWithURL:[self urlForPath:@"/hello"]];
  NSHTTPURLResponse* resp = nil;
  NSData* body = nil;
  [self performRequest:req response:&resp body:&body];

  XCTAssertEqual(resp.statusCode, 200);
  XCTAssertEqualObjects(body, payload);
  XCTAssertTrue([resp.allHeaderFields[@"Content-Type"] hasPrefix:@"text/plain"]);
}

- (void)testGETUnknownPathReturnsNotImplemented {
  [self startServer];

  NSURLRequest* req = [NSURLRequest requestWithURL:[self urlForPath:@"/nope"]];
  NSHTTPURLResponse* resp = nil;
  [self performRequest:req response:&resp body:NULL];

  XCTAssertEqual(resp.statusCode, 501);
}

- (void)testHEADAutoMappedToGET {
  NSData* payload = [@"hello world" dataUsingEncoding:NSUTF8StringEncoding];
  [self.server addGETHandlerForPath:@"/hello"
                         staticData:payload
                        contentType:@"text/plain"
                           cacheAge:0];
  [self startServer];

  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[self urlForPath:@"/hello"]];
  req.HTTPMethod = @"HEAD";
  NSHTTPURLResponse* resp = nil;
  NSData* body = nil;
  [self performRequest:req response:&resp body:&body];

  XCTAssertEqual(resp.statusCode, 200);
  XCTAssertEqual(body.length, (NSUInteger)0);
  NSString* len = resp.allHeaderFields[@"Content-Length"];
  NSString* expectedLen = [NSString stringWithFormat:@"%lu", (unsigned long)payload.length];
  XCTAssertEqualObjects(len, expectedLen);
}

- (void)testRangeRequest {
  NSMutableData* data = [NSMutableData dataWithCapacity:100];
  for (int i = 0; i < 100; i++) {
    uint8_t b = (uint8_t)i;
    [data appendBytes:&b length:1];
  }
  NSString* path = [self writeTempFileWithContents:data extension:@"bin"];

  [self.server addGETHandlerForPath:@"/file"
                           filePath:path
                       isAttachment:NO
                           cacheAge:0
                 allowRangeRequests:YES];
  [self startServer];

  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[self urlForPath:@"/file"]];
  [req setValue:@"bytes=10-19" forHTTPHeaderField:@"Range"];
  NSHTTPURLResponse* resp = nil;
  NSData* body = nil;
  [self performRequest:req response:&resp body:&body];

  XCTAssertEqual(resp.statusCode, 206);
  XCTAssertEqual(body.length, (NSUInteger)10);
  uint8_t expected[10] = {10, 11, 12, 13, 14, 15, 16, 17, 18, 19};
  XCTAssertEqualObjects(body, [NSData dataWithBytes:expected length:10]);
}

- (void)testInvalidRangeRequestIsIgnored {
  NSMutableData* data = [NSMutableData dataWithCapacity:100];
  for (int i = 0; i < 100; i++) {
    uint8_t b = (uint8_t)i;
    [data appendBytes:&b length:1];
  }
  NSString* path = [self writeTempFileWithContents:data extension:@"bin"];

  [self.server addGETHandlerForPath:@"/file"
                           filePath:path
                       isAttachment:NO
                           cacheAge:0
                 allowRangeRequests:YES];
  [self startServer];

  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[self urlForPath:@"/file"]];
  [req setValue:@"bytes=10junk-19" forHTTPHeaderField:@"Range"];
  NSHTTPURLResponse* resp = nil;
  NSData* body = nil;
  [self performRequest:req response:&resp body:&body];

  XCTAssertEqual(resp.statusCode, 200);
  XCTAssertEqualObjects(body, data);
}

- (void)testURLEncodedFormPOST {
  __block NSDictionary* receivedArgs = nil;
  [self.server addHandlerForMethod:@"POST"
                              path:@"/form"
                      requestClass:[GCDWebServerURLEncodedFormRequest class]
                      processBlock:^GCDWebServerResponse*(__kindof GCDWebServerRequest* request) {
                        GCDWebServerURLEncodedFormRequest* form = (GCDWebServerURLEncodedFormRequest*)request;
                        receivedArgs = form.arguments;
                        return [GCDWebServerDataResponse responseWithText:@"ok"];
                      }];
  [self startServer];

  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[self urlForPath:@"/form"]];
  req.HTTPMethod = @"POST";
  [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = [@"key=value&x=1" dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse* resp = nil;
  [self performRequest:req response:&resp body:NULL];

  XCTAssertEqual(resp.statusCode, 200);
  XCTAssertEqualObjects(receivedArgs[@"key"], @"value");
  XCTAssertEqualObjects(receivedArgs[@"x"], @"1");
}

- (void)testMultipartFormPOST {
  __block NSString* receivedField = nil;
  __block NSData* receivedFileData = nil;
  __block NSString* receivedFileName = nil;

  [self.server addHandlerForMethod:@"POST"
                              path:@"/upload"
                      requestClass:[GCDWebServerMultiPartFormRequest class]
                      processBlock:^GCDWebServerResponse*(__kindof GCDWebServerRequest* request) {
                        GCDWebServerMultiPartFormRequest* form = (GCDWebServerMultiPartFormRequest*)request;
                        GCDWebServerMultiPartArgument* textArg = [form firstArgumentForControlName:@"caption"];
                        receivedField = textArg.string;
                        GCDWebServerMultiPartFile* fileArg = [form firstFileForControlName:@"upload"];
                        receivedFileName = fileArg.fileName;
                        if (fileArg.temporaryPath) {
                          receivedFileData = [NSData dataWithContentsOfFile:fileArg.temporaryPath];
                        }
                        return [GCDWebServerDataResponse responseWithText:@"ok"];
                      }];
  [self startServer];

  NSString* boundary = @"----GCDWebServerTestBoundary";
  NSMutableData* body = [NSMutableData data];
  [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  [body appendData:[@"Content-Disposition: form-data; name=\"caption\"\r\n\r\nhi there\r\n"
                       dataUsingEncoding:NSUTF8StringEncoding]];
  [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  [body appendData:[@"Content-Disposition: form-data; name=\"upload\"; filename=\"file.txt\"\r\n"
                       dataUsingEncoding:NSUTF8StringEncoding]];
  [body appendData:[@"Content-Type: text/plain\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  [body appendData:[@"file contents here" dataUsingEncoding:NSUTF8StringEncoding]];
  [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[self urlForPath:@"/upload"]];
  req.HTTPMethod = @"POST";
  [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
      forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = body;
  NSHTTPURLResponse* resp = nil;
  [self performRequest:req response:&resp body:NULL];

  XCTAssertEqual(resp.statusCode, 200);
  XCTAssertEqualObjects(receivedField, @"hi there");
  XCTAssertEqualObjects(receivedFileName, @"file.txt");
  XCTAssertEqualObjects(receivedFileData, [@"file contents here" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testCustomMatchAndProcessBlocks {
  __block NSInteger processCalls = 0;
  [self.server addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* method,
                                                              NSURL* url,
                                                              NSDictionary* headers,
                                                              NSString* path,
                                                              NSDictionary* query) {
    if ([path isEqualToString:@"/match"] && [method isEqualToString:@"GET"]) {
      return [[GCDWebServerRequest alloc] initWithMethod:method
                                                     url:url
                                                 headers:headers
                                                    path:path
                                                   query:query];
    }
    return nil;
  }
      processBlock:^GCDWebServerResponse*(__kindof GCDWebServerRequest* request) {
        processCalls++;
        return [GCDWebServerDataResponse responseWithText:@"matched"];
      }];
  [self startServer];

  NSHTTPURLResponse* matchResp = nil;
  NSData* matchBody = nil;
  [self performRequest:[NSURLRequest requestWithURL:[self urlForPath:@"/match"]]
              response:&matchResp
                  body:&matchBody];
  XCTAssertEqual(matchResp.statusCode, 200);
  XCTAssertEqualObjects([[NSString alloc] initWithData:matchBody encoding:NSUTF8StringEncoding],
                        @"matched");
  XCTAssertEqual(processCalls, 1);

  NSHTTPURLResponse* missResp = nil;
  [self performRequest:[NSURLRequest requestWithURL:[self urlForPath:@"/other"]]
              response:&missResp
                  body:NULL];
  XCTAssertEqual(missResp.statusCode, 501);
  XCTAssertEqual(processCalls, 1);
}

- (void)testServerHeaderOverride {
  [self.server addGETHandlerForPath:@"/x"
                         staticData:[NSData data]
                        contentType:@"text/plain"
                           cacheAge:0];
  [self startServerWithExtraOptions:@{GCDWebServerOption_ServerName : @"MyTestServer"}];

  NSHTTPURLResponse* resp = nil;
  [self performRequest:[NSURLRequest requestWithURL:[self urlForPath:@"/x"]]
              response:&resp
                  body:NULL];
  XCTAssertEqualObjects(resp.allHeaderFields[@"Server"], @"MyTestServer");
}

- (void)testGETHandlerForBasePath {
  NSString* dir = [self makeTempDirectory];
  NSString* htmlPath = [dir stringByAppendingPathComponent:@"index.html"];
  NSString* txtPath = [dir stringByAppendingPathComponent:@"notes.txt"];
  [[@"<html><body>hi</body></html>" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:htmlPath atomically:YES];
  [[@"plain notes" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:txtPath atomically:YES];

  [self.server addGETHandlerForBasePath:@"/site/"
                          directoryPath:dir
                          indexFilename:@"index.html"
                               cacheAge:0
                     allowRangeRequests:NO];
  [self startServer];

  NSHTTPURLResponse* htmlResp = nil;
  NSData* htmlBody = nil;
  [self performRequest:[NSURLRequest requestWithURL:[self urlForPath:@"/site/"]]
              response:&htmlResp
                  body:&htmlBody];
  XCTAssertEqual(htmlResp.statusCode, 200);
  XCTAssertTrue([htmlResp.allHeaderFields[@"Content-Type"] hasPrefix:@"text/html"]);
  XCTAssertEqualObjects(htmlBody,
                        [@"<html><body>hi</body></html>" dataUsingEncoding:NSUTF8StringEncoding]);

  NSHTTPURLResponse* txtResp = nil;
  NSData* txtBody = nil;
  [self performRequest:[NSURLRequest requestWithURL:[self urlForPath:@"/site/notes.txt"]]
              response:&txtResp
                  body:&txtBody];
  XCTAssertEqual(txtResp.statusCode, 200);
  XCTAssertTrue([txtResp.allHeaderFields[@"Content-Type"] hasPrefix:@"text/plain"]);
  XCTAssertEqualObjects(txtBody, [@"plain notes" dataUsingEncoding:NSUTF8StringEncoding]);
}

@end
