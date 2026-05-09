# GCDWebserver

A macOS framework wrapper around [GCDWebServer](https://github.com/swisspol/GCDWebServer) — Pierre-Olivier Latour's lightweight, GCD-based embedded HTTP server for Cocoa.

This is a **fork**. The upstream library is archived and no longer maintained; this fork repackages the core server as an Xcode framework target and adds security hardening fixes specific to its use as the embedded HTTP layer of [ES Memory](https://github.com/apocryphx/ES-Memory). All changes relative to upstream are documented in [`GCDWebserver/CHANGES.md`](GCDWebserver/CHANGES.md).

## What's included

Only the core HTTP server. The upstream's `GCDWebDAVServer` and `GCDWebUploader` are intentionally **not** part of this framework — those features were never used by the consumer of this fork, and dropping them shrinks the public surface and the audit footprint.

| Layer | Headers |
|---|---|
| Core | `GCDWebServer`, `GCDWebServerConnection`, `GCDWebServerRequest`, `GCDWebServerResponse`, `GCDWebServerFunctions`, `GCDWebServerHTTPStatusCodes` |
| Requests | `GCDWebServerDataRequest`, `GCDWebServerFileRequest`, `GCDWebServerURLEncodedFormRequest`, `GCDWebServerMultiPartFormRequest` |
| Responses | `GCDWebServerDataResponse`, `GCDWebServerFileResponse`, `GCDWebServerStreamedResponse`, `GCDWebServerErrorResponse` |

All exposed through the umbrella header [`GCDWebserver/GCDWebserver.h`](GCDWebserver/GCDWebserver.h).

## Requirements

- macOS 26.4 (Sequoia) or later
- Xcode 26 / Apple Clang with C17 + Objective-C ARC
- Apple Silicon or Intel

There is no iOS / tvOS / Mac Catalyst target. The original library supports them; this fork is macOS-only on purpose.

## Build

```bash
xcodebuild -project GCDWebserver.xcodeproj -scheme GCDWebserver -configuration Release build
```

The product is `GCDWebserver.framework`. The project uses Xcode's file-system-synchronized groups, so any source added under `GCDWebserver/` is picked up automatically — no `.pbxproj` edits needed.

## Integration

Link the built `GCDWebserver.framework` into your app target, then:

```objc
@import GCDWebserver;
```

or:

```objc
#import <GCDWebserver/GCDWebserver.h>
```

### Minimal example

```objc
GCDWebServer* server = [[GCDWebServer alloc] init];

[server addDefaultHandlerForMethod:@"GET"
                      requestClass:[GCDWebServerRequest class]
                      processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
    return [GCDWebServerDataResponse responseWithHTML:@"<html><body>hello</body></html>"];
}];

[server startWithOptions:@{
    GCDWebServerOption_Port: @8080,
    GCDWebServerOption_BindToLocalhost: @YES,
} error:NULL];
```

For the full handler / option / authentication API, see the umbrella header.

## Tests

XCTest target with 19 tests covering the public API, server lifecycle, and the fork's security regressions. Documented in [`GCDWebserverTests/README.md`](GCDWebserverTests/README.md).

```bash
xcodebuild test -project GCDWebserver.xcodeproj -scheme GCDWebserver -destination 'platform=macOS'
```

Full suite runs in well under one second; everything is in-process — no fixture files, no external network.

## Security

This fork addresses six vulnerabilities found in a security audit of the upstream code: an unbounded heap allocation from `Content-Length`, a stack overflow in the chunked-encoding parser, unbounded header accumulation, CRLF injection in `WWW-Authenticate`, a static process-lifetime digest nonce with no URI binding, and incomplete HTML escaping in error responses. Each is described in detail in [`GCDWebserver/CHANGES.md`](GCDWebserver/CHANGES.md), and four of them have dedicated regression tests in [`GCDWebserverTests/GCDWebServerSecurityTests.m`](GCDWebserverTests/GCDWebServerSecurityTests.m).

The server is intended to be used bound to `localhost` only (`GCDWebServerOption_BindToLocalhost: @YES`). It has not been audited for use as a public-facing HTTP server, and that is not a supported use case for this fork.

## License

BSD 3-Clause, inherited from upstream — see [`GCDWebserver/LICENSE.txt`](GCDWebserver/LICENSE.txt). Original copyright Pierre-Olivier Latour.

## Credits

- **Original author:** Pierre-Olivier Latour — [github.com/swisspol/GCDWebServer](https://github.com/swisspol/GCDWebServer) (archived)
- **This fork:** Kolja Wawrowsky, packaging and security hardening for [ES Memory](https://github.com/apocryphx/ES-Memory)
