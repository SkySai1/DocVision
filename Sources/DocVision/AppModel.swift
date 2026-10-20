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
- Возвращай только Markdown. Между страницами сохраняй разделение горизонтальной линией (---).
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
    var maxTokens = 4096
    var sourceURL: URL?
    var outputURL: URL?
    var outputDirectory: URL {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: "outputDirectory") }
    }
    var documentPageCount = 0
    var markdownOutput = ""
    var previewMode: DocumentPreviewMode = .preview
    var previewFollowsOutput = true
    var isLoadingModels = false
    var isConverting = false
    var progress = 0.0
    var status = "Выберите PDF и загрузите список моделей."
    var errorMessage: String?
    var canCancel = false

    @ObservationIgnored private var conversionTask: Task<Void, Never>?

    init() {
        let storedDirectory = UserDefaults.standard.string(forKey: "outputDirectory")
        outputDirectory = storedDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".docvision", isDirectory: true)
                .appendingPathComponent("results", isDirectory: true)
        systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? defaultSystemPrompt
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
        markdownOutput = ""
        pageLimit = 0
        outputURL = resultURL(for: url)
        errorMessage = nil
        status = "PDF загружен: \(document.pageCount) стр."
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
            errorMessage = "Сначала выберите PDF и путь для Markdown."
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
        guard let document = PDFDocument(url: sourceURL), document.pageCount > 0 else {
            errorMessage = "Не удалось открыть PDF."
            return
        }

        let destination = outputURL ?? resultURL(for: sourceURL)
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

        let batches = ConversionPlan.pageBatches(pageCount: document.pageCount, pageLimit: pageLimit, batchSize: pagesPerRequest)
        let selectedModel = self.selectedModel
        let prompt = systemPrompt
        let client = client(for: endpointURL)
        let tokenLimit = maxTokens
        errorMessage = nil
        markdownOutput = ""
        isConverting = true
        canCancel = true
        progress = 0
        status = "Подготовка страниц…"
        conversionTask = Task {
            defer {
                isConverting = false
                canCancel = false
                conversionTask = nil
            }
            do {
                for (batchIndex, indexes) in batches.enumerated() {
                    try Task.checkCancellation()
                    status = "Обработка страниц \(indexes.first! + 1)–\(indexes.last! + 1) из \(document.pageCount)…"
                    let images = try Self.renderPages(document: document, indexes: indexes)
                    let pageNumbers = indexes.map { String($0 + 1) }.joined(separator: ", ")
                    let instruction = "Преобразуй страницы PDF № \(pageNumbers) в Markdown. Сохраняй порядок чтения и содержимое. Это часть \(batchIndex + 1) из \(batches.count)."
                    let converted = try await client.convert(
                        systemPrompt: prompt,
                        instruction: instruction,
                        images: images,
                        model: selectedModel,
                        maxTokens: tokenLimit
                    )
                    let first = indexes.first! + 1
                    let last = indexes.last! + 1
                    if !markdownOutput.isEmpty { markdownOutput += "\n\n---\n\n" }
                    markdownOutput += "<!-- Страницы \(first)–\(last) -->\n\n\(converted.trimmingCharacters(in: .whitespacesAndNewlines))"
                    progress = Double(batchIndex + 1) / Double(batches.count)
                }
                try Data(markdownOutput.utf8).write(to: destination, options: .atomic)
                status = "Готово: \(destination.lastPathComponent)"
            } catch is CancellationError {
                status = "Конвертация отменена."
            } catch {
                errorMessage = error.localizedDescription
                status = "Конвертация не завершена."
            }
        }
    }

    func cancelConversion() {
        conversionTask?.cancel()
    }

    private func client(for url: URL) -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: url, apiKey: apiKey, timeout: TimeInterval(max(5, timeoutSeconds)))
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
