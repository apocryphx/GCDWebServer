# Security Hardening Changes (2026-05-09)

## Summary
This change set addresses multiple security and robustness issues in request parsing, upload handling, and static file serving.

## Fixes

1. Path normalization crash hardening
- File: `Core/GCDWebServerFunctions.m`
- `GCDWebServerNormalizePath()` now ignores leading `..` segments when no path component is available to pop.
- Prevents `NSRangeException` crashes from crafted paths.

2. Chunked request body size enforcement
- File: `Core/GCDWebServerConnection.m`
- Added cumulative body accounting for chunked payloads and enforced `kMaxRequestBodySize`.
- Requests exceeding the maximum now return `413 Request Entity Too Large`.

3. Decompressed body size enforcement (gzip bomb mitigation)
- File: `Core/GCDWebServerRequest.m`
- Added a strict cap on decompressed request body bytes in `GCDWebServerGZipDecoder`.
- Oversized decompressed payloads fail with an explicit body-too-large error, resulting in `413`.

4. Secure temporary file creation for uploads
- Files:
  - `Requests/GCDWebServerFileRequest.m`
  - `Requests/GCDWebServerMultiPartFormRequest.m`
- Replaced non-atomic temp file creation (`open` with `O_CREAT|O_TRUNC`) with `mkstemp`.
- Enforced owner-only permissions (`0600`) using `fchmod`.
- Mitigates symlink/race and unintended file-permission exposure risks.

5. Static file serving confinement (symlink-aware)
- File: `GCDWebServer.m`
- `addGETHandlerForBasePath:directoryPath:...` now resolves symlinks and enforces that resolved targets remain under the configured root.
- Out-of-root paths return `403 Forbidden`.

## Additional robustness improvements
- File: `Core/GCDWebServerConnection.m`
- Request body read pipelines now stop and abort with the correct error status when read/write parsing fails, rather than continuing request processing.

## Notes
- Existing tests should continue to pass.
- New behavior for abusive payloads is now deterministic (`400`/`403`/`413` depending on failure type).
