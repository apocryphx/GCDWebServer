# GCDWebServerTests

XCTest target for the `GCDWebServer` framework. **19 tests across 4 files**, all in-process — each test that needs HTTP traffic spins up `GCDWebServer` on `localhost:0` (OS-assigned port) in `setUp` and tears it down in `tearDown`. No fixture files, no external processes, no network.

## Running

```bash
xcodebuild test \
  -project GCDWebServer.xcodeproj \
  -scheme GCDWebServer \
  -destination 'platform=macOS'
```

Or in Xcode: ⌘U on the `GCDWebServer` scheme.

The test action lives in the shared scheme at `GCDWebServer.xcodeproj/xcshareddata/xcschemes/GCDWebServer.xcscheme`. Full suite runs in well under one second.

---

## [GCDWebServerTests.m](GCDWebServerTests.m) — sanity checks

Ported from the upstream `Frameworks/Tests.m`. No HTTP traffic, just object instantiation and pure-function checks.

| Test | Asserts |
|---|---|
| `testWebServerInstantiation` | `[[GCDWebServer alloc] init]` returns non-nil and is not running. |
| `testPathNormalization` | The 14 `GCDWebServerNormalizePath()` cases from the upstream test verbatim — empty input, trailing slashes, `.`/`..` resolution, leading-slash preservation. |

---

## [GCDWebServerHTTPTests.m](GCDWebServerHTTPTests.m) — HTTP request/response path

In-process integration tests against the public handler API. Each test registers handlers, starts the server, makes real `NSURLSession` requests, and validates the response.

| Test | Asserts |
|---|---|
| `testGETStaticData` | `addGETHandlerForPath:staticData:contentType:cacheAge:` returns the bytes verbatim with the configured `Content-Type`. |
| `testGETUnknownPathReturnsNotImplemented` | A request with no matching handler returns 501 (the framework's default-no-handler response, *not* 404). |
| `testHEADAutoMappedToGET` | With default `GCDWebServerOption_AutomaticallyMapHEADToGET`, HEAD on a registered GET path returns 200 with empty body and the GET's `Content-Length`. |
| `testRangeRequest` | `addGETHandlerForPath:filePath:…allowRangeRequests:YES` honors `Range: bytes=10-19` with status 206 and exactly the requested 10 bytes. |
| `testURLEncodedFormPOST` | A handler with `requestClass: GCDWebServerURLEncodedFormRequest.class` parses an `application/x-www-form-urlencoded` body into `request.arguments`. |
| `testMultipartFormPOST` | A handler with `requestClass: GCDWebServerMultiPartFormRequest.class` parses a multipart body into a text argument (`firstArgumentForControlName:`) and a file part with correct filename and contents (`firstFileForControlName:`). |
| `testCustomMatchAndProcessBlocks` | `addHandlerWithMatchBlock:processBlock:` invokes the process block when the match block returns a request, and falls through to 501 (process block *not* called) when match returns nil. |
| `testServerHeaderOverride` | `GCDWebServerOption_ServerName` overrides the default `Server` response header. |
| `testGETHandlerForBasePath` | `addGETHandlerForBasePath:directoryPath:indexFilename:…` serves an index file at the base path and serves siblings by name; `Content-Type` is inferred from the file extension. |

---

## [GCDWebServerLifecycleTests.m](GCDWebServerLifecycleTests.m) — start/stop and delegate

| Test | Asserts |
|---|---|
| `testStartAndStopUpdateRunning` | `isRunning` is `NO` before start, `YES` after `startWithOptions:error:`, and `NO` after `stop`. |
| `testPortIsAssignedWhenZero` | When started with `GCDWebServerOption_Port: @0`, `server.port > 0` (OS picked a port). |
| `testServerURLIsValidWhileRunning` | `serverURL` is non-nil while running, its `port` matches `server.port`, and it becomes nil after `stop`. |
| `testDelegateCallbacks` | `webServerDidStart:` and `webServerDidStop:` both fire, both on the main thread (per the protocol docstring). |

---

## [GCDWebServerSecurityTests.m](GCDWebServerSecurityTests.m) — regression tests for fork-specific security fixes

Each test guards a fix documented in [`../GCDWebServer/CHANGES.md`](../GCDWebServer/CHANGES.md). The fix number column refers to that file.

| Test | Fix | Asserts |
|---|---|---|
| `testOversizedContentLengthRejectedWithoutCrash` | 1 | A POST with a 64 MiB+1 body either gets a 413 response or a connection-reset error (both prove `kMaxRequestBodySize` engaged), and a follow-up `/ping` request succeeds — proving the server didn't crash and recovered. Uses an ephemeral `NSURLSession` so the upload doesn't share a connection pool with other tests. |
| `testRealmCRLFInjectionStrippedFromBasicAuthHeader` | 4 | With `authenticationRealm` set to `"evil\r\nX-Injected: pwned"`, the 401 response carries no `X-Injected` header and the `WWW-Authenticate` value contains no raw `\r` or `\n` — proving `_StripCRLF` ran. |
| `testDigestNonceIsFreshPerConnection` | 5a | Two unauthenticated requests against a Digest-protected endpoint, sent through *separate ephemeral `NSURLSession`s* (forcing separate TCP connections), receive different `nonce=` values in the `WWW-Authenticate` challenge — proving the nonce moved from process-static to per-connection. |
| `testErrorResponseEscapesHTMLMetacharacters` | 6 | A `GCDWebServerErrorResponse` with message `<script>alert("xss")</script> & trouble` produces an HTML body containing `&lt;script&gt;`, `&quot;xss&quot;`, `&amp; trouble` — and **no** raw `<script>` or `</script>` — proving `_EscapeHTMLString` covers `& < > "`. |

### Out of scope

These CHANGES.md fixes are deliberately not tested here:

- **Fix 2** (VLA stack overflow in chunked parser) and **Fix 3** (unbounded header accumulation) — both require sending malformed bytes over a raw TCP socket; `NSURLSession` will not emit them. Adding ~30 LoC of `CFStream` / `NSStream` boilerplate would unblock these.
- **Fix 5b** (Digest URI binding) — would require implementing a full HA1/HA2/response Digest-auth client to forge a valid header for path A and replay it against path B.

---

## Notes on what was *not* ported from upstream

The original GCDWebServer ships a fixture-replay harness (`Run-Tests.sh` + ~720 capture files in `Tests/`). It is not included here because:

1. It depends on `[GCDWebServer runTestsWithOptions:inDirectory:]`, gated behind `__GCDWEBSERVER_ENABLE_TESTING__` — enabling that macro would expand the framework's public surface.
2. Most fixtures cover `GCDWebDAVServer` and `GCDWebUploader`, neither of which is part of this framework.
3. The remaining fixtures replay traffic against handler logic that lives in the upstream's Mac CLI executable, not in the framework itself.

The XCTest cases above replace it with focused, in-process coverage of the framework's actual public API plus the security regressions specific to this fork.
