# TODO

## First release

- [x] Native macOS SwiftUI app and `.app` build script
- [x] PDF input detection by extension and Markdown output selection
- [x] OpenAI-compatible model listing and multimodal chat completion
- [x] Page limit, page batch size, request timeout, and response token limit
- [x] Editable default system prompt with reset and local persistence
- [x] Progress display and conversion cancellation
- [x] Separate Markdown preview window with rendered and editing modes, incremental batch updates, and save
- [x] Persistent results directory setting (default `~/.docvision/results`)
- [x] Unit coverage for page planning and extension detection
- [x] README and application icon source
- [x] Smoke-test all PDF pages in `Samples/` with `qwen3-vl-8b-instruct` at `http://localhost:11436`; all eight requests (up to two pages per request) returned Markdown with HTTP 200
- [ ] Run the XCTest suite on a toolchain that includes XCTest; this machine's Command Line Tools installation does not provide that module.

## Follow-up

- Add format-specific export options when additional output targets are introduced.
- Consider retrying transient server errors while preserving completed page batches.
- Add a conversion history view if users need to revisit prior jobs.
