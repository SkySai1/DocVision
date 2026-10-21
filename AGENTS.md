# DocVision architecture

DocVision is a native macOS desktop app for converting PDF pages into Markdown through an OpenAI-compatible vision-language model API. It targets macOS 14 or newer and is built with Swift Package Manager. The app currently accepts `.pdf` input and writes `.md` output.

## Layers

- `Sources/DocVision/DocVisionApp.swift` creates an `AppWorkspace` shared by multiple independent document windows and their preview windows. Each window receives a session UUID, so files, prompts, settings, results, and cancellation remain scoped to that document.
- `Sources/DocVision/ContentView.swift` contains the session UI: PDF source and Markdown import/export, result selection, persistent results-folder setting, server settings, model selection, conversion controls (including hard and keepalive-based soft timeout modes), editable prompt, progress, and errors. Export offers a clean Markdown copy without DocVision markers or page separators, plus a marked copy for continued editing and page regeneration. It opens additional sessions and the shared queue manager.
- `Sources/DocVision/DocumentPreviewView.swift` presents one session's Markdown in rendered or editable mode, follows completed pages, supports continuous or marker-derived page views, filters/highlights metadata markers, and saves or exports edits. `PageThumbnailSidebar.swift` renders PDF thumbnails, status, selection, and regeneration actions. `GenerationQueueView.swift` lists page jobs and exposes priorities and the concurrent-request limit. `MarkdownPresentation.swift` parses and updates per-page sections; imported multi-page ranges can be regenerated only when horizontal rules split them unambiguously. `MarkdownBlockParser.swift` normalizes common HTML blocks and tables while preserving fenced and inline code, then splits content into renderable Markdown blocks; `MarkdownRenderedView.swift` renders those blocks and inline formatting; `MarkdownSourceEditor.swift` highlights metadata lines.
- `Sources/DocVision/AppModel.swift` owns one document session and coordinates file selection, PDF validation, thumbnail caching, page rendering, incremental Markdown updates, cancellation, and atomic output writing. It stores the results directory in `UserDefaults` and defaults to `~/.docvision/results`. `SourceDocumentType` identifies formats from filename extensions.
- `Sources/DocVision/AppWorkspace.swift` owns session models and the shared page-job queue. It groups adjacent same-priority pages into requests, limits the number of concurrent requests, and starts queued work by priority across all sessions (including multiple page batches from one document). It disambiguates output paths when active sessions target the same file.
- `Sources/DocVision/OpenAICompatibleClient.swift` implements `GET /models`, multimodal `POST /chat/completions`, and optional llama-server slot diagnostics. It sends rendered page images as base64 PNG data URLs, parses response usage/timings when present, supports optional bearer authentication, enforces a full-response deadline in hard timeout mode, and leaves the conversion request open in soft mode while the app checks `/models` keepalive requests.
- `Sources/DocVision/ConversionPlan.swift` contains deterministic page selection, batching, and per-page output-token budget scaling, independent of the interface and network.
- `Tests/DocVisionTests` covers document type detection, page planning/token budgets, and marker-derived Markdown sections.
- `Assets/AppIcon.svg`, `Assets/DocVision.png`, and `Assets/DocVision.icns` are the vector, raster, and macOS icon assets. `Scripts/build-macos-app.sh` builds an unsigned `.app` bundle and embeds the `.icns` file.

## Data flow

1. The user selects a PDF; its extension and `PDFDocument` contents are validated. An existing UTF-8 Markdown file can also be imported before or after selecting the PDF. Recognized `DocVision: page-range` markers populate page statuses and page navigation.
2. The app queries the configured API's `/models` endpoint and lets the user choose a model.
3. Selected PDF pages become individual queue jobs. The workspace starts up to the configured number of requests across all sessions and groups adjacent queued pages from one session up to that session's request-size setting. Multiple page batches from one document may run at once. Queue priorities can be changed before a page starts.
4. Each group and the editable system prompt are sent to `/chat/completions`; completed page sections are inserted by page number so parallel requests and page regeneration do not change document order. A `finish_reason` indicating a length limit marks the final affected page. Hard timeout mode cancels when the full response deadline expires. Soft mode allows long generation and cancels only after a `/models` keepalive request fails within its configured deadline. Response `usage`/`timings` provide last-request tokens and speeds; llama-server `/slots?model=...` optionally supplies context capacity and live slot usage.
5. Markdown is written atomically after each completed request to the selected `.md` destination under the configured results directory. Regenerating a page replaces that page section and preserves other pages. An imported multi-page range must have one horizontal-rule separator per page before a single page can be replaced. Export uses a save dialog and preserves the original imported file unless the user explicitly chooses it. If active sessions target the same output file, the later session receives a numbered filename.

## Development rules

- Keep the UI independent from API serialization and page grouping.
- Keep the OpenAI-compatible API surface configurable by base URL; do not hardcode provider-specific routes beyond `/models` and `/chat/completions`.
- Keep the API key in memory only. The system prompt, timeout mode, and results directory preferences are stored locally in `UserDefaults`.
- Add new input/output types through explicit extension detection and conversion paths. Markdown is the only destination in the first release.
- Preserve PDF page order, honor the page limit and batch size, and propagate cancellation and API errors to the interface.
- Keep session state isolated while coordinating work through `AppWorkspace`; honor the global active-request limit and keep queue statuses synchronized with the Markdown output.
- Keep page markers stable because the thumbnail sidebar, regeneration, page navigation, truncation status, and queue rows all resolve pages through them.
- Run `swift test` for unit checks and `Scripts/build-macos-app.sh` to produce the macOS application bundle.
