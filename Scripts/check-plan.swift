import Foundation

@main
enum ConversionPlanSmokeChecks {
    static func main() {
        precondition(
            ConversionPlan.pageBatches(pageCount: 5, pageLimit: 0, batchSize: 2) == [[0, 1], [2, 3], [4]],
            "Unlimited batches must include every page in order"
        )
        precondition(
            ConversionPlan.pageBatches(pageCount: 10, pageLimit: 3, batchSize: 2) == [[0, 1], [2]],
            "A page limit must stop at the requested count"
        )
        precondition(
            ConversionPlan.pageBatches(pageCount: 3, pageLimit: 0, batchSize: 0) == [[0], [1], [2]],
            "A nonpositive batch size must fall back to one"
        )
        precondition(ConversionPlan.pageBatches(pageCount: 0, pageLimit: 0, batchSize: 1).isEmpty)
        precondition(ConversionPlan.responseTokenLimit(perPage: 4096, pageCount: 1) == 4096)
        precondition(ConversionPlan.responseTokenLimit(perPage: 4096, pageCount: 3) == 12288)
        let emptyDiagnostics = GenerationDiagnostics(
            promptTokens: nil,
            cachedPromptTokens: nil,
            generatedTokens: nil,
            contextTokensUsed: nil,
            promptTokensPerSecond: nil,
            generationTokensPerSecond: nil,
            promptMilliseconds: nil,
            generationMilliseconds: nil
        )
        precondition(ConversionResponse(markdown: "", diagnostics: emptyDiagnostics, finishReason: "length").wasTruncated)
        precondition(!ConversionResponse(markdown: "", diagnostics: emptyDiagnostics, finishReason: "stop").wasTruncated)
        precondition(SourceDocumentType.detect(pathExtension: "PDF") == .pdf)
        precondition(SourceDocumentType.detect(pathExtension: "docx") == nil)

        let customPrompt = "Пользовательский промт\nВторая строка."
        let requestBody = try! OpenAICompatibleClient.makeConversionBody(
            systemPrompt: customPrompt,
            instruction: "Обработай страницу 1.",
            images: ["cG5n"],
            model: "qwen3-vl-8b-instruct",
            maxTokens: 2048
        )
        let requestJSON = try! JSONSerialization.jsonObject(with: requestBody) as! [String: Any]
        let requestMessages = requestJSON["messages"] as! [[String: Any]]
        precondition(requestMessages[0]["role"] as? String == "system")
        precondition(requestMessages[0]["content"] as? String == customPrompt)

        let markdown = """
        <!-- Страницы 1–1 -->
        # Первая
        <!-- Страница 2 -->
        # Вторая
        <!-- DocVision: output-truncated pages 2–2 -->
        """
        let sections = MarkdownPresentation.parse(markdown)
        precondition(sections.map(\.title) == ["Страница 1", "Страница 2"])
        precondition(sections.map(\.markdown) == ["# Первая", "# Вторая"])
        precondition(!sections[0].wasTruncated && sections[1].wasTruncated)
        precondition(sections[1].metadataLines.contains(where: { $0.contains("output-truncated") }))

        let splitPages = MarkdownPresentation.splitResponse("""
        <!-- Страница 4 -->
        # Четвёртая
        <!-- Страница 5 -->
        # Пятая
        """, for: [4, 5])
        precondition(splitPages == [4: "# Четвёртая", 5: "# Пятая"])

        let replacedPage = MarkdownPresentation.replacingPage(2, with: "# Новая вторая", wasTruncated: true, in: """
        <!-- DocVision: page-range 1–1 -->
        # Первая
        ---
        <!-- DocVision: page-range 2–2 -->
        # Старая вторая
        """)
        let replacedSections = MarkdownPresentation.parse(replacedPage)
        precondition(replacedSections.map(\.markdown) == ["# Первая", "# Новая вторая"])
        precondition(replacedSections[1].wasTruncated)

        let importedRange = """
        <!-- DocVision: page-range 64–65 -->
        # Страница 64
        Текст первой страницы.
        ---
        # Страница 65
        Старый текст второй страницы.
        """
        precondition(MarkdownPresentation.canReplacePage(65, in: importedRange))
        let importedRangeAfterReplacement = MarkdownPresentation.replacingPage(
            65,
            with: "# Страница 65\nНовый текст.",
            wasTruncated: false,
            in: importedRange
        )
        let importedRangeSections = MarkdownPresentation.parse(importedRangeAfterReplacement)
        precondition(importedRangeSections.map(\.pageRange?.lowerBound) == [64, 65])
        precondition(importedRangeSections[0].markdown.contains("Текст первой страницы."))
        precondition(importedRangeSections[1].markdown.contains("Новый текст."))

        let separatedBatches = MarkdownPresentation.parse("""
        <!-- DocVision: page-range 1–1 -->
        # Первая
        ---
        <!-- DocVision: page-range 2–2 -->
        # Вторая
        """)
        precondition(separatedBatches.map(\.markdown) == ["# Первая", "# Вторая"])

        let cleanExport = MarkdownPresentation.cleanExport("""
        <!-- DocVision: page-range 1–1 -->
        # Первая

        ---

        <!-- DocVision: page-range 2–2 -->
        # Вторая
        <!-- DocVision: output-truncated pages 2–2 -->
        """)
        precondition(cleanExport == "# Первая\n\n# Вторая")
        precondition(MarkdownPresentation.cleanExport("Текст\n---\nПродолжение") == "Текст\n---\nПродолжение")
        let cleanCodeSample = MarkdownPresentation.cleanExport("""
        <!-- DocVision: page-range 1–1 -->
        ```html
        <!-- DocVision: page-range 7–7 -->
        ---
        ```
        """)
        precondition(cleanCodeSample.contains("<!-- DocVision: page-range 7–7 -->"))
        precondition(cleanCodeSample.contains("\n---\n"))

        let codeSample = """
        ```html
        <!-- Страница 7 -->
        ```
        """
        let codeSections = MarkdownPresentation.parse(codeSample)
        precondition(codeSections.count == 1)
        precondition(codeSections[0].markdown.contains("<!-- Страница 7 -->"))
        precondition(codeSections[0].metadataLines.isEmpty)

        let renderBlocks = MarkdownBlockParser.parse("""
        # Заголовок
        Текст с **выделением**.
        - Пункт
          - Вложенный пункт
        > Цитата
        ```swift
        let value = 1
        ```
        | Поле | Значение |
        | --- | --- |
        | A | B |
        """)
        precondition(renderBlocks.first == .heading(level: 1, text: "Заголовок"))
        precondition(renderBlocks.contains(.quote("Цитата")))
        precondition(renderBlocks.contains(.code(language: "swift", text: "let value = 1")))
        precondition(renderBlocks.contains(.table(headers: ["Поле", "Значение"], rows: [["A", "B"]])))

        let htmlBlocks = MarkdownBlockParser.parse("""
        <h2>Сводка</h2>
        <p>Текст <strong>важен</strong> и <a href="https://example.org">ссылка</a>.</p>
        <table>
          <thead><tr><th>Имя</th><th>Состояние</th></tr></thead>
          <tbody><tr><td>Том &amp; Джерри</td><td><em>готово</em></td></tr></tbody>
        </table>
        <ul><li>Первый</li><li>Второй</li></ul>
        """)
        precondition(htmlBlocks.contains(.heading(level: 2, text: "Сводка")))
        precondition(htmlBlocks.contains(.paragraph("Текст **важен** и [ссылка](https://example.org).")))
        precondition(htmlBlocks.contains(.table(headers: ["Имя", "Состояние"], rows: [["Том & Джерри", "*готово*"]])))
        precondition(htmlBlocks.contains(.list([
            MarkdownListItem(marker: "•", indentation: 0, text: "Первый"),
            MarkdownListItem(marker: "•", indentation: 0, text: "Второй")
        ])))
        let fencedHTML = MarkdownBlockParser.parse("""
        ```html
        <table><tr><td>example</td></tr></table>
        ```
        """)
        precondition(fencedHTML == [.code(language: "html", text: "<table><tr><td>example</td></tr></table>")])
        let inlineHTMLExample = MarkdownBlockParser.parse("Тег `<b>текст</b>` остаётся примером.")
        precondition(inlineHTMLExample == [.paragraph("Тег `<b>текст</b>` остаётся примером.")])

        let wrappedModelResponse = MarkdownPresentation.unwrapOuterMarkdownFence("""
        ```markdown
        # Реальный заголовок
        Текст документа.
        """)
        precondition(wrappedModelResponse == "# Реальный заголовок\nТекст документа.")
        precondition(MarkdownBlockParser.parse(wrappedModelResponse).first == .heading(level: 1, text: "Реальный заголовок"))

        let nextBatchAfterUnclosedFence = """
        ```markdown
        # Незавершённый блок
        <!-- DocVision: page-range 8–8 -->
        # Восьмая страница
        """
        let batchSections = MarkdownPresentation.parse(nextBatchAfterUnclosedFence)
        precondition(batchSections.count == 2)
        precondition(batchSections[1].title == "Страница 8")
        print("DocVision conversion and Markdown checks passed.")
    }
}
