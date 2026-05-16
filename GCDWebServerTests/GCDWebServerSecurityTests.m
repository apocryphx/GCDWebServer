#import <XCTest/XCTest.h>

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

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

- (int)connectedSocketToBaseURL:(NSURL*)baseURL {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  XCTAssertGreaterThanOrEqual(fd, 0);
  if (fd < 0) return -1;

  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
  struct timeval timeout;
  timeout.tv_sec = 5;
  timeout.tv_usec = 0;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons(baseURL.port.unsignedShortValue);
  XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr), 1);

  if (connect(fd, (struct sockaddr*)&address, sizeof(address)) < 0) {
    XCTFail(@"connect failed: %s", strerror(errno));
    close(fd);
    return -1;
  }
  return fd;
}

- (BOOL)writeData:(NSData*)data toSocket:(int)fd allowBrokenPipe:(BOOL)allowBrokenPipe {
  const uint8_t* bytes = data.bytes;
  NSUInteger bytesRemaining = data.length;
  while (bytesRemaining > 0) {
    ssize_t written = write(fd, bytes, bytesRemaining);
    if (written < 0) {
      if (allowBrokenPipe && ((errno == EPIPE) || (errno == ECONNRESET))) {
        return NO;
      }
      XCTFail(@"write failed: %s", strerror(errno));
      return NO;
    }
    bytes += written;
    bytesRemaining -= written;
  }
  return YES;
}

- (NSString*)readRawHTTPResponseFromSocket:(int)fd {
  NSMutableData* responseData = [NSMutableData data];
  uint8_t buffer[4096];
  while (1) {
    ssize_t received = read(fd, buffer, sizeof(buffer));
    if (received < 0) {
      if ((errno == EAGAIN) || (errno == EWOULDBLOCK)) {
        break;
      }
      XCTFail(@"read failed: %s", strerror(errno));
      return nil;
    }
    if (received == 0) {
      break;
    }
    [responseData appendBytes:buffer length:(NSUInteger)received];
  }
  return [[NSString alloc] initWithData:responseData encoding:NSISOLatin1StringEncoding];
}

- (NSString*)rawHTTPResponseForRequestData:(NSData*)requestData baseURL:(NSURL*)baseURL allowBrokenPipe:(BOOL)allowBrokenPipe {
  int fd = [self connectedSocketToBaseURL:baseURL];
  if (fd < 0) return nil;
  [self writeData:requestData toSocket:fd allowBrokenPipe:allowBrokenPipe];
  shutdown(fd, SHUT_WR);
  NSString* response = [self readRawHTTPResponseFromSocket:fd];
  close(fd);
  return response;
}

- (NSString*)rawHTTPResponseForPath:(NSString*)path baseURL:(NSURL*)baseURL {
  NSString* request = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1:%@\r\nConnection: close\r\n\r\n",
                                                 path, baseURL.port];
  return [self rawHTTPResponseForRequestData:[request dataUsingEncoding:NSUTF8StringEncoding]
                                     baseURL:baseURL
                             allowBrokenPipe:NO];
}

- (BOOL)serverStillRespondsAtBaseURL:(NSURL*)baseURL {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
  NSData* expectedBody = [@"alive" dataUsingEncoding:NSUTF8StringEncoding];
  while ([deadline timeIntervalSinceNow] > 0) {
    NSURLRequest* ping =
        [NSURLRequest requestWithURL:[NSURL URLWithString:@"/ping" relativeToURL:baseURL]];
    NSURLSession* session =
        [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSHTTPURLResponse* response = nil;
    NSData* body = nil;
    [self performRequest:ping
              withSession:session
                response:&response
                    body:&body
                   error:NULL
                  timeout:5.0];
    [session finishTasksAndInvalidate];
    if ((response.statusCode == 200) && [body isEqualToData:expectedBody]) {
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  return NO;
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

// Fix 2 — malformed chunk-size lines must be rejected without using attacker-
// controlled stack allocations or crashing the server.
- (void)testOverlongChunkSizeLineRejectedWithoutCrash {
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

  NSMutableString* request = [NSMutableString stringWithFormat:@"POST /upload HTTP/1.1\r\nHost: 127.0.0.1:%@\r\nTransfer-Encoding: chunked\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
                                                                        baseURL.port];
  [request appendString:[@"" stringByPaddingToLength:128 withString:@"f" startingAtIndex:0]];
  [request appendString:@"\r\n"];

  NSString* rawResponse =
      [self rawHTTPResponseForRequestData:[request dataUsingEncoding:NSASCIIStringEncoding]
                                  baseURL:baseURL
                          allowBrokenPipe:NO];
  XCTAssertTrue(rawResponse.length == 0 || [rawResponse hasPrefix:@"HTTP/1.1 400"],
                @"malformed chunk request should be rejected or closed, got: %@", rawResponse);
  XCTAssertTrue([self serverStillRespondsAtBaseURL:baseURL],
                @"Server should still respond after rejecting malformed chunk size");
}

// Fix 3 — request headers must be capped even if a client keeps sending bytes
// before the header terminator.
- (void)testOversizedHeadersRejectedWithoutCrash {
  [self.server addGETHandlerForPath:@"/ping"
                         staticData:[@"alive" dataUsingEncoding:NSUTF8StringEncoding]
                        contentType:@"text/plain"
                           cacheAge:0];
  NSURL* baseURL = [self startWithOptions:nil];

  NSMutableString* request = [NSMutableString stringWithFormat:@"GET /ping HTTP/1.1\r\nHost: 127.0.0.1:%@\r\nX-Pad: ",
                                                                        baseURL.port];
  [request appendString:[@"" stringByPaddingToLength:(70 * 1024) withString:@"a" startingAtIndex:0]];
  [request appendString:@"\r\n\r\n"];

  NSString* rawResponse =
      [self rawHTTPResponseForRequestData:[request dataUsingEncoding:NSASCIIStringEncoding]
                                  baseURL:baseURL
                          allowBrokenPipe:NO];
  XCTAssertTrue(rawResponse.length == 0 || [rawResponse hasPrefix:@"HTTP/1.1 500"],
                @"oversized headers should be rejected or closed, got: %@", rawResponse);
  XCTAssertTrue([self serverStillRespondsAtBaseURL:baseURL],
                @"Server should still respond after rejecting oversized headers");
}

// Chunked uploads are subject to the same 64 MiB request-body cap as requests
// with Content-Length.
- (void)testOversizedChunkedBodyRejectedWithoutCrash {
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

  int fd = [self connectedSocketToBaseURL:baseURL];
  if (fd < 0) return;

  NSString* headers = [NSString stringWithFormat:@"POST /upload HTTP/1.1\r\nHost: 127.0.0.1:%@\r\nTransfer-Encoding: chunked\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n4000001\r\n",
                                                 baseURL.port];
  BOOL writeSucceeded = [self writeData:[headers dataUsingEncoding:NSASCIIStringEncoding]
                               toSocket:fd
                        allowBrokenPipe:YES];

  NSMutableData* payload = [NSMutableData dataWithLength:(256 * 1024)];
  NSUInteger bytesRemaining = (64 * 1024 * 1024) + 1;
  while (writeSucceeded && (bytesRemaining > 0)) {
    NSUInteger bytesToSend = MIN(bytesRemaining, payload.length);
    NSData* chunk = (bytesToSend == payload.length) ? payload : [payload subdataWithRange:NSMakeRange(0, bytesToSend)];
    writeSucceeded = [self writeData:chunk toSocket:fd allowBrokenPipe:YES];
    bytesRemaining -= bytesToSend;
  }
  if (writeSucceeded) {
    [self writeData:[@"\r\n0\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding]
           toSocket:fd
    allowBrokenPipe:YES];
  }
  shutdown(fd, SHUT_WR);
  NSString* rawResponse = [self readRawHTTPResponseFromSocket:fd];
  close(fd);

  XCTAssertTrue(rawResponse.length == 0 ||
                    [rawResponse hasPrefix:@"HTTP/1.1 400"] ||
                    [rawResponse hasPrefix:@"HTTP/1.1 413"],
                @"oversized chunked body should be rejected or closed, got: %@", rawResponse);
  XCTAssertFalse([rawResponse hasPrefix:@"HTTP/1.1 200"],
                 @"oversized chunked body must not be accepted: %@", rawResponse);
  XCTAssertTrue([self serverStillRespondsAtBaseURL:baseURL],
                @"Server should still respond after rejecting oversized chunked body");
}

// Truncated gzip bodies must not be accepted as valid partial request bodies.
- (void)testTruncatedGZipRequestBodyRejectedWithoutProcessing {
  __block BOOL handlerWasCalled = NO;
  [self.server addHandlerForMethod:@"POST"
                              path:@"/gzip"
                      requestClass:[GCDWebServerDataRequest class]
                      processBlock:^GCDWebServerResponse*(GCDWebServerDataRequest* r) {
                        handlerWasCalled = YES;
                        return [GCDWebServerDataResponse responseWithText:@"accepted"];
                      }];
  [self.server addGETHandlerForPath:@"/ping"
                         staticData:[@"alive" dataUsingEncoding:NSUTF8StringEncoding]
                        contentType:@"text/plain"
                           cacheAge:0];
  NSURL* baseURL = [self startWithOptions:nil];

  const uint8_t truncatedGZipBytes[] = {
      0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00
  };
  NSData* body = [NSData dataWithBytes:truncatedGZipBytes length:sizeof(truncatedGZipBytes)];

  NSMutableURLRequest* req =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"/gzip" relativeToURL:baseURL]];
  req.HTTPMethod = @"POST";
  [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
  [req setValue:@"gzip" forHTTPHeaderField:@"Content-Encoding"];
  req.HTTPBody = body;

  NSURLSession* session =
      [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
  NSHTTPURLResponse* resp = nil;
  [self performRequest:req
            withSession:session
              response:&resp
                  body:NULL
                 error:NULL
                timeout:5.0];
  [session finishTasksAndInvalidate];

  XCTAssertNotEqual(resp.statusCode, 200, @"truncated gzip body must not be accepted");
  XCTAssertFalse(handlerWasCalled, @"handler should not process a partial decompressed body");
  XCTAssertTrue([self serverStillRespondsAtBaseURL:baseURL],
                @"Server should still respond after rejecting truncated gzip body");
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

// Directory listings are HTML responses: filenames must be escaped in visible
// link text, not only percent-escaped in href attributes.
- (void)testDirectoryListingEscapesHTMLMetacharactersInFileNames {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  NSString* publicDir = [root stringByAppendingPathComponent:@"public"];
  XCTAssertTrue([fm createDirectoryAtPath:publicDir withIntermediateDirectories:YES attributes:nil error:nil]);

  NSString* fileName = @"<svg onload=alert(1)> & \"quote\".txt";
  NSString* filePath = [publicDir stringByAppendingPathComponent:fileName];
  XCTAssertTrue([@"payload" writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil]);

  [self.server addGETHandlerForBasePath:@"/public/"
                          directoryPath:publicDir
                          indexFilename:nil
                               cacheAge:0
                     allowRangeRequests:NO];
  NSURL* baseURL = [self startWithOptions:nil];

  NSURLRequest* req =
      [NSURLRequest requestWithURL:[NSURL URLWithString:@"/public/" relativeToURL:baseURL]];
  NSHTTPURLResponse* resp = nil;
  NSData* body = nil;
  [self performRequest:req
            withSession:[NSURLSession sharedSession]
              response:&resp
                  body:&body
                 error:NULL
                timeout:5.0];

  XCTAssertEqual(resp.statusCode, 200);
  NSString* html = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(html);
  XCTAssertTrue([html containsString:@"&lt;svg onload=alert(1)&gt; &amp; &quot;quote&quot;.txt"],
                @"filename should be escaped in directory listing: %@", html);
  XCTAssertFalse([html containsString:@"<svg onload=alert(1)>"],
                 @"raw filename HTML survived in directory listing: %@", html);
  [fm removeItemAtPath:root error:nil];
}

// Public response APIs must not allow header names to smuggle extra serialized
// response header lines through CRLF characters.
- (void)testAdditionalHeaderNameCRLFDoesNotInjectResponseHeader {
  [self.server addHandlerForMethod:@"GET"
                              path:@"/headers"
                      requestClass:[GCDWebServerRequest class]
                      processBlock:^GCDWebServerResponse*(__kindof GCDWebServerRequest* r) {
                        GCDWebServerResponse* response = [GCDWebServerDataResponse responseWithText:@"ok"];
                        [response setValue:@"yes" forAdditionalHeader:@"X-Good\r\nX-Injected"];
                        return response;
                      }];
  NSURL* baseURL = [self startWithOptions:nil];

  NSString* rawResponse = [self rawHTTPResponseForPath:@"/headers" baseURL:baseURL];
  XCTAssertNotNil(rawResponse);
  XCTAssertTrue([rawResponse hasPrefix:@"HTTP/1.1 200"], @"unexpected response: %@", rawResponse);
  XCTAssertFalse([rawResponse containsString:@"\r\nX-Injected:"],
                 @"header-name CRLF injected a response header: %@", rawResponse);
  XCTAssertFalse([rawResponse containsString:@"\nX-Injected:"],
                 @"header-name LF injected a response header: %@", rawResponse);
}

// Public response APIs must not allow header values to smuggle extra serialized
// response header lines through CRLF characters.
- (void)testAdditionalHeaderValueCRLFDoesNotInjectResponseHeader {
  [self.server addHandlerForMethod:@"GET"
                              path:@"/headers"
                      requestClass:[GCDWebServerRequest class]
                      processBlock:^GCDWebServerResponse*(__kindof GCDWebServerRequest* r) {
                        GCDWebServerResponse* response = [GCDWebServerDataResponse responseWithText:@"ok"];
                        [response setValue:@"good\r\nX-Injected: yes" forAdditionalHeader:@"X-Good"];
                        return response;
                      }];
  NSURL* baseURL = [self startWithOptions:nil];

  NSString* rawResponse = [self rawHTTPResponseForPath:@"/headers" baseURL:baseURL];
  XCTAssertNotNil(rawResponse);
  XCTAssertTrue([rawResponse hasPrefix:@"HTTP/1.1 200"], @"unexpected response: %@", rawResponse);
  XCTAssertFalse([rawResponse containsString:@"\r\nX-Injected:"],
                 @"header-value CRLF injected a response header: %@", rawResponse);
  XCTAssertFalse([rawResponse containsString:@"\nX-Injected:"],
                 @"header-value LF injected a response header: %@", rawResponse);
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
