import AppKit
import Foundation
import Observation
import PDFKit
import UniformTypeIdentifiers

let defaultSystemPrompt = """
Ты — точный конвертер документов в Markdown. Изучи изображения страниц PDF и преобразуй их содержимое в Markdown.

Правила:
- Сохраняй исходный язык, формулировки, порядок чтения, заголовки, списки и смысловую структуру.
- Передавай таблицы таблицами Markdown; не теряй строки, столбцы и значения.
- Для форм сохраняй подписи полей и их значения. Если поле пустое, оставляй значение пустым и не помечай его как неразборчивое.
- Используй [неразборчиво] только для видимых рукописных символов или текста, которые нельзя уверенно прочитать.
- Не добавляй пояснений, вступлений, ограждающих блоков кода или сведений, которых нет в документе.
- Возвращай только Markdown. Если в запросе несколько страниц, перед содержимым каждой ставь HTML-комментарий <!-- Страница N --> с номером страницы из задания.
"""

enum DocumentPreviewMode: String, CaseIterable, Identifiable {
    case preview
    case editing

    var id: String { rawValue }
    var title: String { self == .preview ? "Просмотр" : "Редактирование" }
}

@MainActor
@Observable
final class AppModel {
    let sessionID: UUID
    @ObservationIgnored weak var workspace: AppWorkspace?
    var endpoint = "http://localhost:11436/v1"
    var apiKey = ""
    var models: [AvailableModel] = []
    var selectedModel = ""
    var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    var pageLimit = 0
    var pagesPerRequest = 1
    var timeoutSeconds = 180
    var timeoutMode: RequestTimeoutMode {
        didSet { UserDefaults.standard.set(timeoutMode.rawValue, forKey: "timeoutMode") }
    }
    var maxTokensPerPage = 4096
    var sourceURL: URL?
    var outputURL: URL?
    var outputDirectory: URL {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: "outputDirectory") }
    }
    var documentPageCount = 0
    var markdownOutput = ""
    var pageStatuses: [Int: GenerationQueueStatus] = [:]
    var importedMarkdownURL: URL?
    var previewMode: DocumentPreviewMode = .preview
    var isQueuePresented = false
    var isThumbnailSidebarVisible = true
    var previewFollowsOutput = true
    var markdownDisplayMode: MarkdownDisplayMode = .continuous
    var markdownSelectedSectionIndex = 0
    var selectedPageNumber: Int?
    var showMarkdownMetadataMarkers = false
    var isLoadingModels = false
    var isConverting = false
    var progress = 0.0
    var lastRequestDiagnostics: GenerationDiagnostics?
    var serverContextWindow: Int?
    var liveContextTokens: Int?
    var status = "Выберите PDF и загрузите список моделей."
    var errorMessage: String?
    var canCancel = false

    @ObservationIgnored private var plannedPageNumbers: Set<Int> = []
    @ObservationIgnored private var completedPageNumbers: Set<Int> = []
    @ObservationIgnored private var thumbnailCache: [Int: NSImage] = [:]
    @ObservationIgnored private var cachedPDF: PDFDocument?
    @ObservationIgnored private var cachedPDFURL: URL?
    @ObservationIgnored private var softTimeoutFailure: String?

    init(sessionID: UUID = UUID(), workspace: AppWorkspace? = nil) {
        self.sessionID = sessionID
        self.workspace = workspace
        let storedDirectory = UserDefaults.standard.string(forKey: "outputDirectory")
        outputDirectory = storedDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".docvision", isDirectory: true)
                .appendingPathComponent("results", isDirectory: true)
        systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? defaultSystemPrompt
        timeoutMode = RequestTimeoutMode(rawValue: UserDefaults.standard.string(forKey: "timeoutMode") ?? "") ?? .hard
    }

    var sourcePageCount: Int { documentPageCount }

    func choosePDF() {
        guard !isConverting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Выбрать PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SourceDocumentType.detect(pathExtension: url.pathExtension) == .pdf else {
            errorMessage = "Поддерживается только PDF."
            return
        }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            errorMessage = "Не удалось открыть PDF. Проверьте файл и доступ к нему."
            return
        }
        sourceURL = url
        documentPageCount = document.pageCount
        cachedPDF = document
        cachedPDFURL = url
        thumbnailCache.removeAll()
        if importedMarkdownURL == nil {
            markdownOutput = ""
            pageStatuses.removeAll()
            markdownSelectedSectionIndex = 0
            selectedPageNumber = nil
        } else {
            refreshImportedPageStatuses()
        }
        pageLimit = 0
        outputURL = resultURL(for: url)
        errorMessage = nil
        status = "PDF загружен: \(document.pageCount) стр."
    }

    func thumbnail(forPage pageNumber: Int) -> NSImage? {
        guard pageNumber > 0, pageNumber <= documentPageCount else { return nil }
        if let image = thumbnailCache[pageNumber] { return image }
        guard let document = cachedPDF(for: sourceURL),
              let page = document.page(at: pageNumber - 1) else { return nil }
        let image = page.thumbnail(of: NSSize(width: 180, height: 240), for: .mediaBox)
        thumbnailCache[pageNumber] = image
        return image
    }

    func selectPage(_ pageNumber: Int) {
        guard pageNumber > 0, pageNumber <= documentPageCount else { return }
        selectedPageNumber = pageNumber
        let sections = MarkdownPresentation.parse(markdownOutput)
        if let index = sections.firstIndex(where: { $0.pageRange?.contains(pageNumber) == true }) {
            markdownSelectedSectionIndex = index
        }
        previewMode = .preview
        markdownDisplayMode = .pages
    }

    func regeneratePage(_ pageNumber: Int, priority: Int = 50) {
        guard pageNumber > 0, pageNumber <= documentPageCount else { return }
        guard let workspace else {
            errorMessage = "Очередь генерации недоступна."
            return
        }
        softTimeoutFailure = nil
        guard !isPageQueuedOrRunning(pageNumber) else { return }
        guard MarkdownPresentation.canReplacePage(pageNumber, in: markdownOutput) else {
            let range = MarkdownPresentation.parse(markdownOutput)
                .first(where: { $0.pageRange?.contains(pageNumber) == true })?.pageRange
            let rangeTitle = range.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "несколько"
            errorMessage = "Нельзя безопасно заменить страницу \(pageNumber): раздел \(rangeTitle) не разделён на отдельные страницы горизонтальными линиями."
            return
        }
        guard !selectedModel.isEmpty else {
            errorMessage = "Загрузите список моделей и выберите VL-модель."
            return
        }
        if outputURL == nil, let sourceURL { outputURL = resultURL(for: sourceURL) }
        guard let proposedOutputURL = outputURL else {
            errorMessage = "Сначала выберите PDF."
            return
        }
        let outputURL = workspace.uniqueOutputURL(for: self, proposed: proposedOutputURL)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            errorMessage = "Не удалось создать папку результатов: \(error.localizedDescription)"
            return
        }
        self.outputURL = outputURL
        self.outputDirectory = outputURL.deletingLastPathComponent()
        plannedPageNumbers.insert(pageNumber)
        completedPageNumbers.remove(pageNumber)
        errorMessage = nil
        workspace.enqueue(self, pageNumbers: [pageNumber], priority: priority)
    }

    func isPageQueuedOrRunning(_ pageNumber: Int) -> Bool {
        guard let status = pageStatuses[pageNumber] else { return false }
        return status == .queued || status == .running
    }

    func chooseOutput() {
        guard !isConverting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? "Документ.md"
        panel.prompt = "Сохранить Markdown"
        if panel.runModal() == .OK, let url = panel.url {
            let destination = url.deletingPathExtension().appendingPathExtension("md")
            outputURL = destination
            outputDirectory = destination.deletingLastPathComponent()
        }
    }

    func importMarkdown() {
        guard !isConverting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Импортировать Markdown"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Импортированный Markdown пуст."
                return
            }
            markdownOutput = content
            importedMarkdownURL = url
            outputURL = nil
            errorMessage = nil
            previewMode = .preview
            previewFollowsOutput = false
            let sections = MarkdownPresentation.parse(content)
            let markedSections = sections.filter { $0.pageRange != nil }
            markdownDisplayMode = markedSections.isEmpty ? .continuous : .pages
            markdownSelectedSectionIndex = sections.firstIndex(where: { $0.pageRange != nil }) ?? 0
            selectedPageNumber = markedSections.first?.pageRange?.lowerBound
            refreshImportedPageStatuses()
            if markedSections.isEmpty {
                status = "Markdown импортирован. Маркеры страниц не найдены; выберите PDF для перегенерации страниц."
            } else {
                status = "Markdown импортирован: найдено разделов с маркерами страниц — \(markedSections.count)."
            }
        } catch {
            errorMessage = "Не удалось импортировать Markdown: \(error.localizedDescription)"
        }
    }

    func exportMarkdown(clean: Bool = true) {
        guard !markdownOutput.isEmpty else {
            errorMessage = "Сначала импортируйте или создайте Markdown."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = outputURL?.deletingLastPathComponent()
            ?? importedMarkdownURL?.deletingLastPathComponent()
            ?? outputDirectory
        if let outputURL {
            let stem = outputURL.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = clean ? "\(stem) (чистый).md" : outputURL.lastPathComponent
        } else if let importedMarkdownURL {
            let suffix = clean ? " (чистый)" : " (DocVision)"
            panel.nameFieldStringValue = importedMarkdownURL.deletingPathExtension().lastPathComponent + suffix + ".md"
        } else {
            panel.nameFieldStringValue = clean ? "Документ (чистый).md" : "Документ.md"
        }
        panel.prompt = "Экспортировать Markdown"
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let destination = selectedURL.deletingPathExtension().appendingPathExtension("md")
        if clean, let outputURL,
           destination.standardizedFileURL == outputURL.standardizedFileURL {
            errorMessage = "Сохраните чистый экспорт в отдельный файл, чтобы не заменить рабочий Markdown с разметкой страниц."
            return
        }
        do {
            let content = clean ? MarkdownPresentation.cleanExport(markdownOutput) : markdownOutput
            try Data(content.utf8).write(to: destination, options: .atomic)
            if !clean {
                outputURL = destination
                outputDirectory = destination.deletingLastPathComponent()
            }
            status = "\(clean ? "Чистый Markdown" : "Markdown с разметкой") экспортирован: \(destination.lastPathComponent)"
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось экспортировать Markdown: \(error.localizedDescription)"
        }
    }

    func chooseOutputDirectory() {
        guard !isConverting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.prompt = "Выбрать папку результатов"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        outputDirectory = directory
        if let sourceURL { outputURL = resultURL(for: sourceURL) }
        status = "Папка результатов: \(directory.path)"
        errorMessage = nil
    }

    func restorePrompt() {
        systemPrompt = defaultSystemPrompt
    }

    func saveMarkdown() {
        guard let outputURL else {
            exportMarkdown()
            return
        }
        do {
            try Data(markdownOutput.utf8).write(to: outputURL, options: .atomic)
            status = "Сохранено: \(outputURL.lastPathComponent)"
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось сохранить Markdown: \(error.localizedDescription)"
        }
    }

    func refreshModels() {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = ClientError.invalidEndpoint.localizedDescription
            return
        }
        isLoadingModels = true
        errorMessage = nil
        status = "Загружаю модели…"
        Task {
            defer { isLoadingModels = false }
            do {
                let result = try await client(for: url).fetchModels()
                models = result
                if !models.contains(where: { $0.id == selectedModel }) {
                    selectedModel = models.first?.id ?? ""
                }
                status = models.isEmpty ? "Сервер доступен, но список моделей пуст." : "Найдено моделей: \(models.count)."
            } catch {
                errorMessage = error.localizedDescription
                status = "Не удалось получить модели."
            }
        }
    }

    func startConversion() {
        guard !isConverting else { return }
        guard let sourceURL else {
            errorMessage = "Сначала выберите PDF."
            return
        }
        guard SourceDocumentType.detect(pathExtension: sourceURL.pathExtension) == .pdf else {
            errorMessage = "Тип исходного файла определяется по расширению; поддерживается только .pdf."
            return
        }
        guard !selectedModel.isEmpty else {
            errorMessage = "Загрузите список моделей и выберите VL-модель."
            return
        }
        guard let endpointURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(endpointURL.scheme?.lowercased() ?? "") else {
            errorMessage = ClientError.invalidEndpoint.localizedDescription
            return
        }
        guard let document = cachedPDF(for: sourceURL), document.pageCount > 0 else {
            errorMessage = "Не удалось открыть PDF."
            return
        }
        guard let workspace else {
            errorMessage = "Очередь генерации недоступна."
            return
        }

        let destination = workspace.uniqueOutputURL(for: self, proposed: outputURL ?? resultURL(for: sourceURL))
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            errorMessage = "Не удалось создать папку результатов: \(error.localizedDescription)"
            return
        }
        outputURL = destination
        outputDirectory = destination.deletingLastPathComponent()

        let pageNumbers = ConversionPlan.pageBatches(
            pageCount: document.pageCount,
            pageLimit: pageLimit,
            batchSize: 1
        ).flatMap { $0.map { $0 + 1 } }
        errorMessage = nil
        softTimeoutFailure = nil
        markdownOutput = ""
        importedMarkdownURL = nil
        markdownSelectedSectionIndex = 0
        selectedPageNumber = nil
        lastRequestDiagnostics = nil
        serverContextWindow = nil
        liveContextTokens = nil
        progress = 0
        completedPageNumbers.removeAll()
        plannedPageNumbers = Set(pageNumbers)
        pageStatuses.removeAll()
        status = "Страницы добавляются в очередь…"
        workspace.enqueue(self, pageNumbers: pageNumbers)
    }

    func cancelConversion() {
        workspace?.cancelSession(sessionID)
    }

    func queueDidStart(pageNumbers: [Int]) {
        isConverting = true
        canCancel = true
        status = pageNumbers.count == 1
            ? "Страница \(pageNumbers[0]) добавлена в очередь."
            : "В очередь добавлено страниц: \(pageNumbers.count)."
    }

    func queueDidFinish() {
        isConverting = false
        canCancel = false
        liveContextTokens = nil
        progress = plannedPageNumbers.isEmpty ? progress : Double(completedPageNumbers.count) / Double(plannedPageNumbers.count)
        let failures = plannedPageNumbers.filter { pageStatuses[$0]?.failureMessage != nil }.sorted()
        let cancelledPages = plannedPageNumbers.filter { pageStatuses[$0] == .cancelled }.sorted()
        if let softTimeoutFailure {
            errorMessage = softTimeoutFailure
            status = "Генерация остановлена."
        } else if !failures.isEmpty {
            status = "Очередь завершена с ошибками: страницы \(failures.map(String.init).joined(separator: ", "))."
        } else if !cancelledPages.isEmpty {
            status = "Генерация отменена. Завершено страниц: \(completedPageNumbers.count) из \(plannedPageNumbers.count)."
        } else if !plannedPageNumbers.isEmpty {
            status = "Готово: \(outputURL?.lastPathComponent ?? "Markdown")"
        }
        plannedPageNumbers.removeAll()
        completedPageNumbers.removeAll()
    }

    func processPages(_ pageNumbers: [Int]) async -> Set<Int> {
        guard let sourceURL,
              let document = cachedPDF(for: sourceURL),
              let endpointURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(endpointURL.scheme?.lowercased() ?? ""),
              !selectedModel.isEmpty else {
            for pageNumber in pageNumbers { pageStatuses[pageNumber] = .failed("Не удалось открыть PDF или адрес сервера.") }
            return []
        }

        let selectedModel = self.selectedModel
        let prompt = systemPrompt
        let client = client(for: endpointURL)
        let tokenLimit = max(128, maxTokensPerPage)
        let selectedTimeoutMode = timeoutMode
        let diagnosticsTask = Task { await self.monitorServerSlots(client: client, model: selectedModel) }
        let keepaliveTask: Task<Void, Never>? = selectedTimeoutMode == .soft
            ? Task { await self.monitorKeepalive(client: client) }
            : nil
        defer {
            diagnosticsTask.cancel()
            keepaliveTask?.cancel()
            if (workspace?.activeRequestCount(for: sessionID) ?? 1) <= 1 {
                liveContextTokens = nil
            }
        }

        do {
            try Task.checkCancellation()
            status = pageNumbers.count == 1
                ? "Обработка страницы \(pageNumbers[0]) из \(documentPageCount)…"
                : "Обработка страниц \(pageNumbers.first!)–\(pageNumbers.last!) из \(documentPageCount)…"
            let indexes = pageNumbers.map { $0 - 1 }
            let images = try Self.renderPages(document: document, indexes: indexes)
            let instruction: String
            if pageNumbers.count == 1 {
                instruction = "Преобразуй страницу PDF № \(pageNumbers[0]) в Markdown. Сохраняй порядок чтения и всё содержимое страницы."
            } else {
                instruction = "Преобразуй страницы PDF № \(pageNumbers.map(String.init).joined(separator: ", ")) в Markdown. Сохраняй порядок чтения и всё содержимое. Раздели результат маркерами HTML-комментариев вида <!-- Страница N -->, где N — номер соответствующей страницы. Верни отдельный маркер для каждой страницы."
            }
            let response = try await client.convert(
                systemPrompt: prompt,
                instruction: instruction,
                images: images,
                model: selectedModel,
                maxTokens: ConversionPlan.responseTokenLimit(perPage: tokenLimit, pageCount: pageNumbers.count),
                timeoutMode: selectedTimeoutMode
            )
            try Task.checkCancellation()
            lastRequestDiagnostics = response.diagnostics
            guard let pageMarkdown = MarkdownPresentation.splitResponse(response.markdown, for: pageNumbers) else {
                throw ClientError.invalidResponse("Ответ не удалось разделить по страницам \(pageNumbers.first!)–\(pageNumbers.last!). Уменьшите число страниц за запрос до 1 или уточните системный промт.")
            }

            for pageNumber in pageNumbers {
                guard let pageText = pageMarkdown[pageNumber] else {
                    pageStatuses[pageNumber] = .failed("В ответе отсутствует содержимое страницы.")
                    continue
                }
                let isTruncated = response.wasTruncated && pageNumber == pageNumbers.last
                markdownOutput = MarkdownPresentation.replacingPage(
                    pageNumber,
                    with: pageText,
                    wasTruncated: isTruncated,
                    in: markdownOutput
                )
                if isTruncated {
                    pageStatuses[pageNumber] = .failed("Ответ оборван по лимиту токенов; конец страницы может быть неполным.")
                } else {
                    pageStatuses[pageNumber] = .completed
                    completedPageNumbers.insert(pageNumber)
                }
            }
            try persistMarkdown()
            if let outputURL { status = "Страница\(pageNumbers.count == 1 ? "а" : "и") \(pageNumbers.map(String.init).joined(separator: ", ")) сохранена: \(outputURL.lastPathComponent)" }
            updateProgress()
            return Set(pageNumbers.filter { pageStatuses[$0] == .completed })
        } catch is CancellationError {
            for pageNumber in pageNumbers where pageStatuses[pageNumber] == .running {
                pageStatuses[pageNumber] = .cancelled
            }
            if let softTimeoutFailure { errorMessage = softTimeoutFailure }
            return []
        } catch {
            let message = error.localizedDescription
            for pageNumber in pageNumbers where pageStatuses[pageNumber] == .running {
                pageStatuses[pageNumber] = .failed(message)
            }
            errorMessage = message
            return []
        }
    }

    private func client(for url: URL) -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: url, apiKey: apiKey, timeout: TimeInterval(max(5, timeoutSeconds)))
    }

    private func monitorServerSlots(client: OpenAICompatibleClient, model: String) async {
        try? await Task.sleep(for: .milliseconds(800))
        var unavailableAttempts = 0
        while !Task.isCancelled {
            if let snapshot = await client.fetchSlotSnapshot(model: model) {
                unavailableAttempts = 0
                serverContextWindow = snapshot.contextSize
                liveContextTokens = snapshot.isProcessing ? snapshot.contextTokensUsed : nil
            } else {
                unavailableAttempts += 1
                if unavailableAttempts >= 3 { return }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func monitorKeepalive(client: OpenAICompatibleClient) async {
        while !Task.isCancelled {
            do {
                try await client.keepalive()
            } catch {
                guard !Task.isCancelled else { return }
                softTimeoutFailure = "Мягкий таймаут: keepalive GET /v1/models не ответил за \(max(5, timeoutSeconds)) сек. Конвертация остановлена."
                workspace?.cancelSession(sessionID)
                return
            }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

    private func cachedPDF(for url: URL?) -> PDFDocument? {
        guard let url else { return nil }
        if cachedPDFURL == url, let cachedPDF { return cachedPDF }
        guard let document = PDFDocument(url: url) else { return nil }
        cachedPDF = document
        cachedPDFURL = url
        return document
    }

    private func persistMarkdown() throws {
        guard let outputURL else { return }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(markdownOutput.utf8).write(to: outputURL, options: .atomic)
    }

    private func updateProgress() {
        guard !plannedPageNumbers.isEmpty else { return }
        let finishedCount = plannedPageNumbers.filter { pageNumber in
            guard let status = pageStatuses[pageNumber] else { return false }
            return !status.isPending
        }.count
        progress = Double(finishedCount) / Double(plannedPageNumbers.count)
    }

    private func refreshImportedPageStatuses() {
        pageStatuses.removeAll()
        guard documentPageCount > 0 else { return }
        for section in MarkdownPresentation.parse(markdownOutput) {
            guard let range = section.pageRange else { continue }
            let firstPage = max(1, range.lowerBound)
            let lastPage = min(documentPageCount, range.upperBound)
            guard firstPage <= lastPage else { continue }
            for pageNumber in firstPage...lastPage {
                pageStatuses[pageNumber] = .completed
            }
        }
        if let selectedPageNumber, selectedPageNumber > documentPageCount {
            self.selectedPageNumber = pageStatuses.keys.sorted().first
        }
    }

    private func resultURL(for sourceURL: URL) -> URL {
        outputDirectory.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("md")
    }

    private static func renderPages(document: PDFDocument, indexes: [Int]) throws -> [String] {
        try indexes.map { index in
            guard let page = document.page(at: index) else {
                throw ClientError.invalidResponse("Не удалось прочитать страницу \(index + 1).")
            }
            let image = page.thumbnail(of: NSSize(width: 1600, height: 2200), for: .mediaBox)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ClientError.invalidResponse("Не удалось подготовить изображение страницы \(index + 1).")
            }
            return png.base64EncodedString()
        }
    }
}
