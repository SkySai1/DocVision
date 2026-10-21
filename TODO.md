# TODO

## First release

- [x] Native macOS SwiftUI app and `.app` build script
- [x] PDF input detection by extension and Markdown output selection
- [x] OpenAI-compatible model listing and multimodal chat completion
- [x] Page limit, page batch size, hard deadline and keepalive-based soft timeout modes, and response token limit
- [x] Editable default system prompt with reset and local persistence
- [x] Progress display and conversion cancellation
- [x] Separate Markdown preview window with rendered and editing modes, incremental batch updates, and save
- [x] Continuous or marker-derived page preview, online metadata filtering, and highlighted marker lines
- [x] Per-page output-token budgets and truncation markers for responses that end at the API token limit
- [x] Show last-request token counts and generation speeds, plus live llama-server context-window usage when available
- [x] Persistent results directory setting (default `~/.docvision/results`)
- [x] Independent document sessions in multiple windows, with a shared concurrent request queue
- [x] PDF thumbnail sidebar with page selection and per-page regeneration
- [x] Queue manager with page status, adjustable priority, cancellation, and concurrent-request limit
- [x] Incremental page replacement in Markdown while preserving page order during concurrent work and regeneration
- [x] Import and export UTF-8 Markdown with page markers; safely regenerate pages from imported single-page ranges or clearly separated multi-page ranges
- [x] Unit coverage for page planning, per-page token budgets, extension detection, and Markdown markers
- [x] README and application icon source
- [x] Smoke-test all PDF pages in `Samples/` with `qwen3-vl-8b-instruct` at `http://localhost:11436`; all eight requests (up to two pages per request) returned Markdown with HTTP 200
- [ ] Run the XCTest suite on a toolchain that includes XCTest; this machine's Command Line Tools installation does not provide that module.

## Follow-up

- Add format-specific export options when additional output targets are introduced.
- Consider retrying transient server errors while preserving completed page batches.
- Consider persisting conversion history across app launches if users need to revisit prior sessions.
