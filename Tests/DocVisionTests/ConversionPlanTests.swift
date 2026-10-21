import XCTest
@testable import DocVision

final class ConversionPlanTests: XCTestCase {
    func testUnlimitedPagesAreGroupedInOrder() {
        XCTAssertEqual(ConversionPlan.pageBatches(pageCount: 5, pageLimit: 0, batchSize: 2), [[0, 1], [2, 3], [4]])
    }

    func testPageLimitStopsAtDocumentBoundary() {
        XCTAssertEqual(ConversionPlan.pageBatches(pageCount: 10, pageLimit: 3, batchSize: 2), [[0, 1], [2]])
        XCTAssertEqual(ConversionPlan.pageBatches(pageCount: 2, pageLimit: 10, batchSize: 1), [[0], [1]])
    }

    func testInvalidBatchSizeFallsBackToOne() {
        XCTAssertEqual(ConversionPlan.pageBatches(pageCount: 3, pageLimit: 0, batchSize: 0), [[0], [1], [2]])
    }

    func testEmptyDocumentHasNoBatches() {
        XCTAssertEqual(ConversionPlan.pageBatches(pageCount: 0, pageLimit: 0, batchSize: 1), [])
    }

    func testResponseTokenBudgetIsPerPageAndScalesWithBatchSize() {
        XCTAssertEqual(ConversionPlan.responseTokenLimit(perPage: 4096, pageCount: 1), 4096)
        XCTAssertEqual(ConversionPlan.responseTokenLimit(perPage: 4096, pageCount: 3), 12288)
        XCTAssertEqual(ConversionPlan.responseTokenLimit(perPage: 0, pageCount: 2), 256)
    }

    func testExtensionDetectionIgnoresCaseAndRejectsUnknownTypes() {
        XCTAssertEqual(SourceDocumentType.detect(pathExtension: "PDF"), .pdf)
        XCTAssertNil(SourceDocumentType.detect(pathExtension: "docx"))
    }
}

final class OpenAICompatibleClientTests: XCTestCase {
    func testCustomSystemPromptIsSerializedUnchangedAsFirstMessage() throws {
        let prompt = "Пользовательский промт: сохранить заголовки.\nНе подменять текст."
        let data = try OpenAICompatibleClient.makeConversionBody(
            systemPrompt: prompt,
            instruction: "Обработай страницу 1.",
            images: ["cG5n"],
            model: "qwen3-vl-8b-instruct",
            maxTokens: 2048
        )

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, prompt)
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(body["model"] as? String, "qwen3-vl-8b-instruct")
    }
}

final class MarkdownPresentationTests: XCTestCase {
    func testLengthFinishReasonIdentifiesTruncatedResponse() {
        let diagnostics = GenerationDiagnostics(
            promptTokens: nil,
            cachedPromptTokens: nil,
            generatedTokens: nil,
            contextTokensUsed: nil,
            promptTokensPerSecond: nil,
            generationTokensPerSecond: nil,
            promptMilliseconds: nil,
            generationMilliseconds: nil
        )
        XCTAssertTrue(ConversionResponse(markdown: "body", diagnostics: diagnostics, finishReason: "length").wasTruncated)
        XCTAssertFalse(ConversionResponse(markdown: "body", diagnostics: diagnostics, finishReason: "stop").wasTruncated)
    }

    func testPageMarkersCreateSectionsAndTruncationMarkerAnnotatesPage() {
        let source = """
        <!-- Страницы 1–1 -->
        # Первая
        <!-- Страница 2 -->
        # Вторая
        <!-- DocVision: output-truncated pages 2–2 -->
        """

        let sections = MarkdownPresentation.parse(source)
        XCTAssertEqual(sections.map(\.title), ["Страница 1", "Страница 2"])
        XCTAssertEqual(sections.map(\.markdown), ["# Первая", "# Вторая"])
        XCTAssertFalse(sections[0].wasTruncated)
        XCTAssertTrue(sections[1].wasTruncated)
        XCTAssertTrue(sections[1].metadataLines.contains(where: { $0.contains("output-truncated") }))
    }

    func testMetadataLikeLineInsideCodeFenceRemainsDocumentContent() {
        let source = """
        ```html
        <!-- Страница 7 -->
        ```
        """

        let sections = MarkdownPresentation.parse(source)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Документ")
        XCTAssertTrue(sections[0].markdown.contains("<!-- Страница 7 -->"))
        XCTAssertTrue(sections[0].metadataLines.isEmpty)
    }

    func testBatchResponseSplitsByExplicitPageMarkers() {
        let response = """
        <!-- Страница 4 -->
        # Четвёртая
        <!-- Страница 5 -->
        # Пятая
        """

        XCTAssertEqual(
            MarkdownPresentation.splitResponse(response, for: [4, 5]),
            [4: "# Четвёртая", 5: "# Пятая"]
        )
    }

    func testReplacingPagePreservesOtherPagesAndMarksTruncation() {
        let source = """
        <!-- DocVision: page-range 1–1 -->
        # Первая
        ---
        <!-- DocVision: page-range 2–2 -->
        # Старая вторая
        """

        let result = MarkdownPresentation.replacingPage(2, with: "# Новая вторая", wasTruncated: true, in: source)
        let sections = MarkdownPresentation.parse(result)
        XCTAssertEqual(sections.map(\.markdown), ["# Первая", "# Новая вторая"])
        XCTAssertTrue(sections[1].wasTruncated)
        XCTAssertTrue(result.contains("output-truncated pages 2–2"))
    }

    func testImportedMultiPageRangeCanReplaceOnePageOnlyWhenSeparated() {
        let source = """
        <!-- DocVision: page-range 64–65 -->
        # Страница 64
        Текст первой страницы.
        ---
        # Страница 65
        Старый текст второй страницы.
        """
        XCTAssertTrue(MarkdownPresentation.canReplacePage(65, in: source))

        let result = MarkdownPresentation.replacingPage(65, with: "# Страница 65\nНовый текст.", wasTruncated: false, in: source)
        let sections = MarkdownPresentation.parse(result)
        XCTAssertEqual(sections.map(\.pageRange?.lowerBound), [64, 65])
        XCTAssertTrue(sections[0].markdown.contains("Текст первой страницы."))
        XCTAssertTrue(sections[1].markdown.contains("Новый текст."))
    }

    func testImportedMultiPageRangeWithoutSeparatorsCannotBeReplaced() {
        let source = """
        <!-- DocVision: page-range 64–65 -->
        # Страница 64
        # Страница 65
        """
        XCTAssertFalse(MarkdownPresentation.canReplacePage(65, in: source))
    }
}

final class MarkdownBlockParserTests: XCTestCase {
    func testModelMarkdownWrapperIsRemovedEvenWhenResponseWasTruncated() {
        let response = """
        ```markdown
        # Техническое задание
        Обычный **текст**.
        """

        let markdown = MarkdownPresentation.unwrapOuterMarkdownFence(response)
        XCTAssertEqual(markdown, "# Техническое задание\nОбычный **текст**.")
        XCTAssertEqual(MarkdownBlockParser.parse(markdown).first, .heading(level: 1, text: "Техническое задание"))
    }

    func testModelMarkdownWrapperWithClosingFenceIsRemoved() {
        let response = """
        ```md
        - Первый пункт
        ```
        """

        XCTAssertEqual(MarkdownPresentation.unwrapOuterMarkdownFence(response), "- Первый пункт")
    }

    func testParsesCommonMarkdownBlocksForNativeRendering() {
        let blocks = MarkdownBlockParser.parse("""
        # Отчёт
        Абзац с **выделением**.

        - Первый
          - Вложенный
        1. Второй
        > Цитата

        ```swift
        let value = 1
        ```

        | Название | Число |
        |:---|---:|
        | тест | 3 |

        ---
        """)

        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Отчёт"))
        XCTAssertEqual(blocks[1], .paragraph("Абзац с **выделением**."))
        XCTAssertEqual(blocks[2], .list([
            MarkdownListItem(marker: "•", indentation: 0, text: "Первый"),
            MarkdownListItem(marker: "•", indentation: 2, text: "Вложенный"),
            MarkdownListItem(marker: "1.", indentation: 0, text: "Второй")
        ]))
        XCTAssertEqual(blocks[3], .quote("Цитата"))
        XCTAssertEqual(blocks[4], .code(language: "swift", text: "let value = 1"))
        XCTAssertEqual(blocks[5], .table(headers: ["Название", "Число"], rows: [["тест", "3"]]))
        XCTAssertEqual(blocks[6], .divider)
    }

    func testPreservesEscapedPipesInsideTableCells() {
        let blocks = MarkdownBlockParser.parse("""
        Имя | Выражение
        --- | ---
        A | x \\| y
        """)

        XCTAssertEqual(blocks, [.table(headers: ["Имя", "Выражение"], rows: [["A", "x | y"]])])
    }

    func testRendersHTMLBlocksInlineTagsAndTables() {
        let blocks = MarkdownBlockParser.parse("""
        <h2>Сводка</h2>
        <p>Текст <strong>важен</strong> и <a href="https://example.org">ссылка</a>.</p>
        <table>
          <thead><tr><th>Имя</th><th>Состояние</th></tr></thead>
          <tbody><tr><td>Том &amp; Джерри</td><td><em>готово</em></td></tr></tbody>
        </table>
        <ul><li>Первый</li><li>Второй</li></ul>
        """)

        XCTAssertTrue(blocks.contains(.heading(level: 2, text: "Сводка")))
        XCTAssertTrue(blocks.contains(.paragraph("Текст **важен** и [ссылка](https://example.org).")))
        XCTAssertTrue(blocks.contains(.table(headers: ["Имя", "Состояние"], rows: [["Том & Джерри", "*готово*"]])))
        XCTAssertTrue(blocks.contains(.list([
            MarkdownListItem(marker: "•", indentation: 0, text: "Первый"),
            MarkdownListItem(marker: "•", indentation: 0, text: "Второй")
        ])))
    }

    func testLeavesHTMLExamplesInsideMarkdownCodeFencesUntouched() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("""
            ```html
            <table><tr><td>example</td></tr></table>
            ```
            """),
            [.code(language: "html", text: "<table><tr><td>example</td></tr></table>")]
        )
    }

    func testLeavesHTMLInsideInlineMarkdownCodeUntouched() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("Тег `<b>текст</b>` остаётся примером."),
            [.paragraph("Тег `<b>текст</b>` остаётся примером.")]
        )
    }
}
