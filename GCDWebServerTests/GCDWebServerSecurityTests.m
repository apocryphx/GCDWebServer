#import <XCTest/XCTest.h>

@import GCDWebServer;

@interface GCDWebServerSecurityTests : XCTestCase
@property(nonatomic, strong) GCDWebServer* server;
@end

@implementation GCDWebServerSecurityTests

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

#pragma mark - Helpers

- (NSURL*)startWithOptions:(NSDictionary*)extra {
  NSMutableDictionary* opts = [@{
    GCDWebServerOption_Port : @0,
    GCDWebServerOption_BindToLocalhost : @YES,
    // Match the test thread QoS so stop() doesn't wait on lower-QoS source cancel handlers.
    GCDWebServerOption_DispatchQueuePriority : @(QOS_CLASS_USER_INTERACTIVE),
  } mutableCopy];
  if (extra) [opts addEntriesFromDictionary:extra];
  NSError* error = nil;
  XCTAssertTrue([self.server startWithOptions:opts error:&error], @"Server failed to start: %@", error);
  return self.server.serverURL;
}

- (void)performRequest:(NSURLRequest*)request
            withSession:(NSURLSession*)session
              response:(NSHTTPURLResponse* _Nullable __autoreleasing* _Nullable)outResponse
                  body:(NSData* _Nullable __autoreleasing* _Nullable)outBody
                 error:(NSError* _Nullable __autoreleasing* _Nullable)outError
                timeout:(NSTimeInterval)timeout {
  XCTestExpectation* expectation = [self expectationWithDescription:@"http"];
  __block NSHTTPURLResponse* response = nil;
  __block NSData* body = nil;
  __block NSError* err = nil;
  NSURLSessionDataTask* task =
      [session dataTaskWithRequest:request
                 completionHandler:^(NSData* data, NSURLResponse* resp, NSError* e) {
                   response = (NSHTTPURLResponse*)resp;
                   body = data;
                   err = e;
                   [expectation fulfill];
                 }];
  [task resume];
  [self waitForExpectations:@[ expectation ] timeout:timeout];
  if (outResponse) *outResponse = response;
  if (outBody) *outBody = body;
  if (outError) *outError = err;
}

- (NSString*)nonceFromAuthHeader:(NSString*)header {
  if (!header) return nil;
  NSRegularExpression* re =
      [NSRegularExpression regularExpressionWithPattern:@"nonce=\"([^\"]+)\""
                                                options:0
                                                  error:nil];
  NSTextCheckingResult* m =
      [re firstMatchInString:header options:0 range:NSMakeRange(0, header.length)];
  if (!m || m.numberOfRanges < 2) return nil;
  return [header substringWithRange:[m rangeAtIndex:1]];
}

- (NSString*)wwwAuthenticateFrom:(NSHTTPURLResponse*)response {
  NSDictionary* h = response.allHeaderFields;
  return h[@"WWW-Authenticate"] ?: h[@"Www-Authenticate"] ?: h[@"www-authenticate"];
}

#pragma mark - Tests

// Fix 1 — kMaxRequestBodySize (64 MB) cap on Content-Length.
// The server should reject with 413 before reading the body, and remain alive
// to serve subsequent requests.
- (void)testOversizedContentLengthRejectedWithoutCrash {
  [self.server addHandlerForMethod:@"POST"
                              path:@"/upload"
                      requestClass:[GCDWebServerDataRequest class]
                      processBlock:^GCDWebServerResponse*(__kindof GCDWebServerRequest* r) {
                        return [GCDWebServerDataResponse responseWithText:@"ok"];
                      }];
  [self.server addGETHandlerForPath:@"/ping"
                         staticData:[@"alive" dataUsingEncoding:NSUTF8StringEncoding]
                        contentType:@"text/plain"
                           cacheAge:0];
  NSURL* baseURL = [self startWithOptions:nil];

  NSMutableURLRequest* big = [NSMutableURLRequest
      requestWithURL:[NSURL URLWithString:@"/upload" relativeToURL:baseURL]];
  big.HTTPMethod = @"POST";
  [big setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
  // 64 MiB + 1 — exceeds kMaxRequestBodySize.
  big.HTTPBody = [NSMutableData dataWithLength:(64 * 1024 * 1024) + 1];

  // Use an ephemeral session so this 64 MiB upload doesn't share a connection
  // pool with other tests in the suite — sharedSession can stall here.
  NSURLSession* uploadSession =
      [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
  NSHTTPURLResponse* resp = nil;
  NSError* err = nil;
  [self performRequest:big
            withSession:uploadSession
              response:&resp
                  body:NULL
                 error:&err
                timeout:30.0];
  [uploadSession finishTasksAndInvalidate];

  // The client may either receive the 413 cleanly, or get a "connection lost"
  // error if the server closes mid-upload. Both outcomes prove the body cap
  // engaged; the must-not-happen case is a server crash. Confirm the server
  // is still alive by serving a follow-up request.
  if (resp) {
    XCTAssertEqual(resp.statusCode, 413, @"Expected 413 Request Entity Too Large");
  } else {
    XCTAssertNotNil(err, @"Either a 413 response or a network error was expected");
  }

  NSURLSession* pingSession =
      [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
  NSURLRequest* ping =
      [NSURLRequest requestWithURL:[NSURL URLWithString:@"/ping" relativeToURL:baseURL]];
  NSHTTPURLResponse* pingResp = nil;
  NSData* pingBody = nil;
  [self performRequest:ping
            withSession:pingSession
              response:&pingResp
                  body:&pingBody
                 error:NULL
                timeout:10.0];
  [pingSession finishTasksAndInvalidate];
  XCTAssertEqual(pingResp.statusCode, 200, @"Server should still serve requests after rejecting oversized upload");
  XCTAssertEqualObjects(pingBody, [@"alive" dataUsingEncoding:NSUTF8StringEncoding]);
}

// Fix 4 — _StripCRLF on authenticationRealm prevents response-splitting
// via injected CRLF in the WWW-Authenticate header.
- (void)testRealmCRLFInjectionStrippedFromBasicAuthHeader {
  [self.server addGETHandlerForPath:@"/protected"
                         staticData:[@"secret" dataUsingEncoding:NSUTF8StringEncoding]
                        contentType:@"text/plain"
                           cacheAge:0];
  NSURL* baseURL = [self startWithOptions:@{
    GCDWebServerOption_AuthenticationMethod : GCDWebServerAuthenticationMethod_Basic,
    GCDWebServerOption_AuthenticationRealm : @"evil\r\nX-Injected: pwned",
    GCDWebServerOption_AuthenticationAccounts : @{@"u" : @"p"},
  }];

  NSURLRequest* req =
      [NSURLRequest requestWithURL:[NSURL URLWithString:@"/protected" relativeToURL:baseURL]];
  NSHTTPURLResponse* resp = nil;
  [self performRequest:req
            withSession:[NSURLSession sharedSession]
              response:&resp
                  body:NULL
                 error:NULL
                timeout:5.0];

  XCTAssertEqual(resp.statusCode, 401);
  // The smuggled header must not have been injected as a real response header.
  XCTAssertNil(resp.allHeaderFields[@"X-Injected"]);
  // The WWW-Authenticate value must contain no raw CRLF — that is what would
  // have allowed the trailing "X-Injected: pwned" to be parsed by an HTTP
  // client as a separate response header. The literal text still appearing
  // inside the realm is harmless once CRLF is stripped.
  NSString* wwwAuth = [self wwwAuthenticateFrom:resp];
  XCTAssertNotNil(wwwAuth);
  XCTAssertFalse([wwwAuth containsString:@"\r"], @"realm not stripped: %@", wwwAuth);
  XCTAssertFalse([wwwAuth containsString:@"\n"], @"realm not stripped: %@", wwwAuth);
}

// Fix 5a — Per-connection digest nonce.
// Two requests on independent connections must receive different nonces.
- (void)testDigestNonceIsFreshPerConnection {
  [self.server addGETHandlerForPath:@"/x"
                         staticData:[@"secret" dataUsingEncoding:NSUTF8StringEncoding]
                        contentType:@"text/plain"
                           cacheAge:0];
  NSURL* baseURL = [self startWithOptions:@{
    GCDWebServerOption_AuthenticationMethod : GCDWebServerAuthenticationMethod_DigestAccess,
    GCDWebServerOption_AuthenticationRealm : @"realm",
    GCDWebServerOption_AuthenticationAccounts : @{@"u" : @"p"},
  }];
  NSURL* url = [NSURL URLWithString:@"/x" relativeToURL:baseURL];

  NSString* nonceA = [self nonceForURL:url];
  NSString* nonceB = [self nonceForURL:url];

  XCTAssertNotNil(nonceA);
  XCTAssertNotNil(nonceB);
  XCTAssertNotEqualObjects(nonceA, nonceB,
                           @"Each connection must receive a fresh nonce; got identical values");
}

- (NSString*)nonceForURL:(NSURL*)url {
  // Ephemeral session forces a fresh connection pool — no keep-alive reuse
  // from a previous request.
  NSURLSession* session =
      [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
  NSHTTPURLResponse* resp = nil;
  [self performRequest:[NSURLRequest requestWithURL:url]
            withSession:session
              response:&resp
                  body:NULL
                 error:NULL
                timeout:5.0];
  [session finishTasksAndInvalidate];
  XCTAssertEqual(resp.statusCode, 401);
  return [self nonceFromAuthHeader:[self wwwAuthenticateFrom:resp]];
}

// Fix 6 — _EscapeHTMLString escapes the full set: & < > "
- (void)testErrorResponseEscapesHTMLMetacharacters {
  [self.server addHandlerForMethod:@"GET"
                              path:@"/err"
                      requestClass:[GCDWebServerRequest class]
                      processBlock:^GCDWebServerResponse*(__kindof GCDWebServerRequest* r) {
                        return [GCDWebServerErrorResponse
                            responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                            message:@"<script>alert(\"xss\")</script> & trouble"];
                      }];
  NSURL* baseURL = [self startWithOptions:nil];

  NSURLRequest* req =
      [NSURLRequest requestWithURL:[NSURL URLWithString:@"/err" relativeToURL:baseURL]];
  NSHTTPURLResponse* resp = nil;
  NSData* body = nil;
  [self performRequest:req
            withSession:[NSURLSession sharedSession]
              response:&resp
                  body:&body
                 error:NULL
                timeout:5.0];

  XCTAssertEqual(resp.statusCode, 400);
  NSString* html = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(html);

  // All four metacharacters must be escaped in the rendered message.
  XCTAssertTrue([html containsString:@"&lt;script&gt;"], @"< and > must be escaped: %@", html);
  XCTAssertTrue([html containsString:@"&lt;/script&gt;"], @"closing tag must be escaped: %@", html);
  XCTAssertTrue([html containsString:@"&quot;xss&quot;"], @"\" must be escaped: %@", html);
  XCTAssertTrue([html containsString:@"&amp; trouble"], @"& must be escaped: %@", html);

  // The raw script tag must not survive into the body.
  XCTAssertFalse([html containsString:@"<script>"], @"raw <script> survived: %@", html);
  XCTAssertFalse([html containsString:@"</script>"], @"raw </script> survived: %@", html);
}

// Fix 7 — path normalization should not crash on leading ".." and
// traversal attempts must not escape the configured base directory.
- (void)testBasePathTraversalWithDotDotIsForbidden {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  NSString* publicDir = [root stringByAppendingPathComponent:@"public"];
  XCTAssertTrue([fm createDirectoryAtPath:publicDir withIntermediateDirectories:YES attributes:nil error:nil]);

  [self.server addGETHandlerForBasePath:@"/public/"
                          directoryPath:publicDir
                          indexFilename:nil
                               cacheAge:0
                     allowRangeRequests:NO];
  NSURL* baseURL = [self startWithOptions:nil];

  NSURL* attackURL = [NSURL URLWithString:@"/public/%2e%2e/secret.txt" relativeToURL:baseURL];
  NSHTTPURLResponse* resp = nil;
  [self performRequest:[NSURLRequest requestWithURL:attackURL]
            withSession:[NSURLSession sharedSession]
              response:&resp
                  body:NULL
                 error:NULL
                timeout:5.0];

  // Traversal input must not crash or escape; implementation may return 403 or 404.
  XCTAssertTrue((resp.statusCode == 403) || (resp.statusCode == 404));
  [fm removeItemAtPath:root error:nil];
}

// Fix 8 — symlink targets outside the configured static root must be denied.
- (void)testBasePathSymlinkEscapeIsForbidden {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  NSString* publicDir = [root stringByAppendingPathComponent:@"public"];
  NSString* privateDir = [root stringByAppendingPathComponent:@"private"];
  XCTAssertTrue([fm createDirectoryAtPath:publicDir withIntermediateDirectories:YES attributes:nil error:nil]);
  XCTAssertTrue([fm createDirectoryAtPath:privateDir withIntermediateDirectories:YES attributes:nil error:nil]);

  NSString* secretPath = [privateDir stringByAppendingPathComponent:@"secret.txt"];
  XCTAssertTrue([@"top-secret" writeToFile:secretPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);

  NSString* linkPath = [publicDir stringByAppendingPathComponent:@"leak.txt"];
  XCTAssertTrue([fm createSymbolicLinkAtPath:linkPath withDestinationPath:secretPath error:nil]);

  [self.server addGETHandlerForBasePath:@"/public/"
                          directoryPath:publicDir
                          indexFilename:nil
                               cacheAge:0
                     allowRangeRequests:NO];
  NSURL* baseURL = [self startWithOptions:nil];

  NSURL* leakURL = [NSURL URLWithString:@"/public/leak.txt" relativeToURL:baseURL];
  NSHTTPURLResponse* resp = nil;
  [self performRequest:[NSURLRequest requestWithURL:leakURL]
            withSession:[NSURLSession sharedSession]
              response:&resp
                  body:NULL
                 error:NULL
                timeout:5.0];

  XCTAssertEqual(resp.statusCode, 403);
  [fm removeItemAtPath:root error:nil];
}

@end
