# DocVision architecture

DocVision is a native macOS desktop app for converting PDF pages into Markdown through an OpenAI-compatible vision-language model API. It targets macOS 14 or newer and is built with Swift Package Manager. The app currently accepts `.pdf` input and writes `.md` output.

## Layers

- `Sources/DocVision/ContentView.swift` contains the SwiftUI interface: source and destination selection, persistent results-folder setting, server settings, model selection, conversion controls, editable prompt, progress, and errors.
- `Sources/DocVision/DocumentPreviewView.swift` presents the shared Markdown result in rendered or editable mode, follows newly completed batches, and saves user edits.
- `Sources/DocVision/AppModel.swift` owns shared UI state and coordinates file selection, PDF validation, page rendering, batching, cancellation, incremental preview updates, and atomic output writing. It stores the results directory in `UserDefaults` and defaults to `~/.docvision/results`. `SourceDocumentType` identifies formats from filename extensions.
- `Sources/DocVision/OpenAICompatibleClient.swift` implements `GET /models` and multimodal `POST /chat/completions`. It sends rendered page images as base64 PNG data URLs and supports optional bearer authentication.
- `Sources/DocVision/ConversionPlan.swift` contains deterministic page selection and batching logic, independent of the interface and network.
- `Tests/DocVisionTests` covers document type detection and page planning.
- `Assets/AppIcon.svg`, `Assets/DocVision.png`, and `Assets/DocVision.icns` are the vector, raster, and macOS icon assets. `Scripts/build-macos-app.sh` builds an unsigned `.app` bundle and embeds the `.icns` file.

## Data flow

1. The user selects a PDF; its extension and `PDFDocument` contents are validated.
2. The app queries the configured API's `/models` endpoint and lets the user choose a model.
3. Selected PDF pages are rendered with PDFKit to PNG images and grouped by the configured request size.
4. Each group and the editable system prompt are sent to `/chat/completions`; Markdown is appended to the shared document after each group so the preview can show finished pages while later groups are still processing.
5. The completed UTF-8 Markdown is written atomically to the selected `.md` destination under the configured results directory. If the user picks a specific output file, its parent becomes the configured directory.

## Development rules

- Keep the UI independent from API serialization and page grouping.
- Keep the OpenAI-compatible API surface configurable by base URL; do not hardcode provider-specific routes beyond `/models` and `/chat/completions`.
- Keep the API key in memory only. The system prompt and results directory preferences are stored locally in `UserDefaults`.
- Add new input/output types through explicit extension detection and conversion paths. Markdown is the only destination in the first release.
- Preserve PDF page order, honor the page limit and batch size, and propagate cancellation and API errors to the interface.
- Run `swift test` for unit checks and `Scripts/build-macos-app.sh` to produce the macOS application bundle.
