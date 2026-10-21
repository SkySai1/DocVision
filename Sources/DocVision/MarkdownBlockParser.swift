import Foundation

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case quote(String)
    case code(language: String?, text: String)
    case table(headers: [String], rows: [[String]])
    case divider
}

struct MarkdownListItem: Equatable {
    let marker: String
    let indentation: Int
    let text: String
}

enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = normalizeHTML(markdown).components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = openingFence(in: line) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if isClosingFence(lines[index], matching: fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               hasUnescapedPipe(line),
               isTableDelimiter(lines[index + 1]) {
                let headers = splitTableRow(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, hasUnescapedPipe(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitTableRow(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if isHorizontalRule(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if isBlockquote(line) {
                var quoteLines: [String] = []
                while index < lines.count, isBlockquote(lines[index]) {
                    quoteLines.append(quotedContent(lines[index]))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: " ")))
                continue
            }

            if let firstItem = parseListItem(line) {
                var items = [firstItem]
                index += 1
                while index < lines.count {
                    if let item = parseListItem(lines[index]) {
                        items.append(item)
                        index += 1
                        continue
                    }

                    let continuation = lines[index]
                    let indentation = leadingIndentation(in: continuation)
                    if !continuation.trimmingCharacters(in: .whitespaces).isEmpty,
                       indentation > (items.last?.indentation ?? 0) {
                        let content = continuation.trimmingCharacters(in: .whitespaces)
                        items[items.count - 1] = MarkdownListItem(
                            marker: items[items.count - 1].marker,
                            indentation: items[items.count - 1].indentation,
                            text: items[items.count - 1].text + " " + content
                        )
                        index += 1
                        continue
                    }
                    break
                }
                blocks.append(.list(items))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(at: index, in: lines) {
                paragraphLines.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(joinParagraphLines(paragraphLines)))
        }

        return blocks
    }

    private static func normalizeHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var htmlLines: [String] = []
        var output: [String] = []
        var openFence: (character: Character, length: Int, language: String?)?

        func flushHTML() {
            guard !htmlLines.isEmpty else { return }
            output.append(convertHTMLFragment(htmlLines.joined(separator: "\n")))
            htmlLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if let fence = openFence {
                output.append(line)
                if isClosingFence(line, matching: fence) { openFence = nil }
            } else if let fence = openingFence(in: line) {
                flushHTML()
                output.append(line)
                openFence = fence
            } else {
                htmlLines.append(line)
            }
        }
        flushHTML()
        return output.joined(separator: "\n")
    }

    private static func convertHTMLFragment(_ fragment: String) -> String {
        var protectedPreBlocks: [String: String] = [:]
        var protectedInlineCode: [String: String] = [:]
        var result = replaceMatches(
            in: fragment,
            pattern: #"(?s)(`+)(.+?)\1"#
        ) { match, source in
            let code = capture(match, at: 0, in: source)
            let placeholder = "DOCVISION_INLINE_CODE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            protectedInlineCode[placeholder] = code
            return placeholder
        }
        result = replaceMatches(
            in: result,
            pattern: #"(?is)<pre\b([^>]*)>(.*?)</pre\s*>"#
        ) { match, source in
            let attributes = capture(match, at: 1, in: source)
            var body = capture(match, at: 2, in: source)
            var language = htmlAttribute("class", in: body)?
                .split(whereSeparator: { $0 == " " || $0 == "-" })
                .last.map(String.init)
            if language == nil { language = htmlAttribute("class", in: attributes) }
            body = replaceMatches(in: body, pattern: #"(?is)</?code\b[^>]*>"#) { _, _ in "" }
            body = decodeHTMLEntities(stripHTMLTags(body))
                .trimmingCharacters(in: .newlines)
            let fence = "```\(language ?? "")\n\(body)\n```"
            let placeholder = "DOCVISION_HTML_PRE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            protectedPreBlocks[placeholder] = fence
            return "\n\n\(placeholder)\n\n"
        }

        result = replaceMatches(
            in: result,
            pattern: #"(?is)<table\b[^>]*>.*?</table\s*>"#
        ) { match, source in
            htmlTableToMarkdown(capture(match, at: 0, in: source))
        }

        result = replaceMatches(in: result, pattern: #"(?is)<!--.*?-->"#) { _, _ in "" }
        result = replaceMatches(in: result, pattern: #"(?is)<hr\b[^>]*?/?>"#) { _, _ in "\n\n---\n\n" }
        result = replaceMatches(in: result, pattern: #"(?is)<h([1-6])\b[^>]*>"#) { match, source in
            let level = capture(match, at: 1, in: source)
            return "\n\n\(String(repeating: "#", count: Int(level) ?? 1)) "
        }
        result = replaceMatches(in: result, pattern: #"(?is)</h[1-6]\s*>"#) { _, _ in "\n\n" }
        result = replaceMatches(in: result, pattern: #"(?is)<(?:p|div|section|article|header|footer|main|figure|figcaption)\b[^>]*>"#) { _, _ in "\n\n" }
        result = replaceMatches(in: result, pattern: #"(?is)</(?:p|div|section|article|header|footer|main|figure|figcaption)\s*>"#) { _, _ in "\n\n" }
        result = replaceMatches(in: result, pattern: #"(?is)<br\b[^>]*?/?>"#) { _, _ in "\n" }
        result = replaceMatches(in: result, pattern: #"(?is)<(?:ul|ol)\b[^>]*>"#) { _, _ in "\n" }
        result = replaceMatches(in: result, pattern: #"(?is)</(?:ul|ol)\s*>"#) { _, _ in "\n" }
        result = replaceMatches(in: result, pattern: #"(?is)<li\b[^>]*>"#) { _, _ in "\n- " }
        result = replaceMatches(in: result, pattern: #"(?is)</li\s*>"#) { _, _ in "" }
        result = replaceMatches(in: result, pattern: #"(?is)<blockquote\b[^>]*>"#) { _, _ in "\n\n> " }
        result = replaceMatches(in: result, pattern: #"(?is)</blockquote\s*>"#) { _, _ in "\n\n" }
        result = replaceMatches(in: result, pattern: #"(?is)<details\b[^>]*>"#) { _, _ in "\n\n" }
        result = replaceMatches(in: result, pattern: #"(?is)</details\s*>"#) { _, _ in "\n\n" }
        result = replaceMatches(in: result, pattern: #"(?is)<summary\b[^>]*>"#) { _, _ in "\n\n**" }
        result = replaceMatches(in: result, pattern: #"(?is)</summary\s*>"#) { _, _ in "**\n\n" }
        result = transformInlineHTML(result)
        result = decodeHTMLEntities(stripHTMLTags(result))
        for (placeholder, code) in protectedPreBlocks {
            result = result.replacingOccurrences(of: placeholder, with: code)
        }
        for (placeholder, code) in protectedInlineCode {
            result = result.replacingOccurrences(of: placeholder, with: code)
        }
        return result
    }

    private static func htmlTableToMarkdown(_ table: String) -> String {
        let caption = firstCapture(in: table, pattern: #"(?is)<caption\b[^>]*>(.*?)</caption\s*>"#)
            .map { htmlInlineText($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let rowMatches = matches(in: table, pattern: #"(?is)<tr\b[^>]*>(.*?)</tr\s*>"#)
        var parsedRows: [[(isHeader: Bool, text: String)]] = []

        for rowMatch in rowMatches {
            let rowHTML = capture(rowMatch, at: 1, in: table)
            let cells = matches(in: rowHTML, pattern: #"(?is)<(th|td)\b[^>]*>(.*?)</(?:th|td)\s*>"#)
                .map { cellMatch -> (Bool, String) in
                    let isHeader = capture(cellMatch, at: 1, in: rowHTML).lowercased() == "th"
                    let text = htmlInlineText(capture(cellMatch, at: 2, in: rowHTML))
                    return (isHeader, text.replacingOccurrences(of: "|", with: #"\|"#))
                }
            if !cells.isEmpty { parsedRows.append(cells) }
        }

        guard !parsedRows.isEmpty else { return htmlInlineText(table) }
        let headerIndex = parsedRows.firstIndex(where: { row in row.contains(where: { $0.isHeader }) }) ?? 0
        let headers = parsedRows[headerIndex].map { $0.text }
        let bodyRows = Array(parsedRows[..<headerIndex]) + Array(parsedRows[(headerIndex + 1)...])
        let width = max(headers.count, bodyRows.map { $0.count }.max() ?? 0)
        guard width > 0 else { return "" }

        func row(_ cells: [String]) -> String {
            let padded = (0..<width).map { $0 < cells.count ? cells[$0] : "" }
            return "| " + padded.joined(separator: " | ") + " |"
        }

        let normalizedHeaders = (0..<width).map { $0 < headers.count ? headers[$0] : "" }
        let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        var output = [row(normalizedHeaders), separator]
        output.append(contentsOf: bodyRows.map { row($0.map { $0.text }) })
        if let caption, !caption.isEmpty {
            output.insert("**\(caption)**", at: 0)
        }
        return "\n\n" + output.joined(separator: "\n") + "\n\n"
    }

    private static func transformInlineHTML(_ source: String) -> String {
        var result = replaceMatches(
            in: source,
            pattern: #"(?is)<a\b([^>]*)>(.*?)</a\s*>"#
        ) { match, value in
            let attributes = capture(match, at: 1, in: value)
            let label = transformInlineHTML(capture(match, at: 2, in: value))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = htmlAttribute("href", in: attributes), !url.isEmpty else { return label }
            return "[\(label)](\(decodeHTMLEntities(url)))"
        }
        result = replaceMatches(in: result, pattern: #"(?is)<img\b([^>]*)/?>"#) { match, value in
            let attributes = capture(match, at: 1, in: value)
            let alt = htmlAttribute("alt", in: attributes) ?? ""
            let src = htmlAttribute("src", in: attributes) ?? ""
            return src.isEmpty ? alt : "![\(decodeHTMLEntities(alt))](\(decodeHTMLEntities(src)))"
        }

        let replacements: [(String, String)] = [
            (#"(?is)<\s*(?:strong|b)\b[^>]*>"#, "**"), (#"(?is)</\s*(?:strong|b)\s*>"#, "**"),
            (#"(?is)<\s*(?:em|i)\b[^>]*>"#, "*"), (#"(?is)</\s*(?:em|i)\s*>"#, "*"),
            (#"(?is)<\s*(?:del|s|strike)\b[^>]*>"#, "~~"), (#"(?is)</\s*(?:del|s|strike)\s*>"#, "~~"),
            (#"(?is)<\s*code\b[^>]*>"#, "`"), (#"(?is)</\s*code\s*>"#, "`"),
            (#"(?is)<\s*sup\b[^>]*>"#, "^"), (#"(?is)</\s*sup\s*>"#, "^"),
            (#"(?is)<\s*sub\b[^>]*>"#, "~"), (#"(?is)</\s*sub\s*>"#, "~")
        ]
        for (pattern, replacement) in replacements {
            result = replaceMatches(in: result, pattern: pattern) { _, _ in replacement }
        }
        result = replaceMatches(in: result, pattern: #"(?is)<br\b[^>]*?/?>"#) { _, _ in " " }
        return result
    }

    private static func htmlInlineText(_ source: String) -> String {
        let blockTagsRemoved = replaceMatches(
            in: source,
            pattern: #"(?is)</?(?:p|div|section|article|br|ul|ol|li)\b[^>]*>"#
        ) { _, _ in " " }
        let transformed = transformInlineHTML(blockTagsRemoved)
        let text = decodeHTMLEntities(stripHTMLTags(transformed))
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func htmlAttribute(_ name: String, in source: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let match = matches(
            in: source,
            pattern: #"(?is)\b"# + escapedName + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        ).first else { return nil }
        for captureIndex in 1...3 {
            let value = capture(match, at: captureIndex, in: source)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func stripHTMLTags(_ source: String) -> String {
        replaceMatches(in: source, pattern: #"(?is)</?[a-z][^>]*>"#) { _, _ in "" }
    }

    private static func decodeHTMLEntities(_ source: String) -> String {
        var result = source
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return replaceMatches(in: result, pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: [.caseInsensitive]) { match, value in
            let entity = capture(match, at: 1, in: value)
            let scalar: UInt32?
            if entity.lowercased().hasPrefix("x") {
                scalar = UInt32(entity.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(entity, radix: 10)
            }
            guard let scalar, let character = UnicodeScalar(scalar) else { return "" }
            return String(character)
        }
    }

    private static func firstCapture(in source: String, pattern: String) -> String? {
        guard let match = matches(in: source, pattern: pattern).first else { return nil }
        return capture(match, at: 1, in: source)
    }

    private static func matches(in source: String, pattern: String) -> [NSTextCheckingResult] {
        matches(in: source, pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func matches(
        in source: String,
        pattern: String,
        options: NSRegularExpression.Options
    ) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
    }

    private static func capture(_ match: NSTextCheckingResult, at index: Int, in source: String) -> String {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: source) else { return "" }
        return String(source[range])
    }

    private static func replaceMatches(
        in source: String,
        pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators],
        with transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return source }
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
        guard !matches.isEmpty else { return source }
        let output = NSMutableString(string: source)
        for match in matches.reversed() {
            output.replaceCharacters(in: match.range, with: transform(match, source))
        }
        return output as String
    }

    private static func startsBlock(at index: Int, in lines: [String]) -> Bool {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if openingFence(in: line) != nil || parseHeading(trimmed) != nil || isHorizontalRule(trimmed) {
            return true
        }
        if isBlockquote(line) || parseListItem(line) != nil {
            return true
        }
        return index + 1 < lines.count && hasUnescapedPipe(line) && isTableDelimiter(lines[index + 1])
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let characters = Array(line)
        let level = characters.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), level < characters.count, characters[level].isWhitespace else { return nil }
        let text = String(characters.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        let closingMarksRemoved = text.replacingOccurrences(
            of: #"\s+#+\s*$"#,
            with: "",
            options: .regularExpression
        )
        return (level, closingMarksRemoved)
    }

    private static func openingFence(in line: String) -> (character: Character, length: Int, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        guard let marker = characters.first, marker == "`" || marker == "~" else { return nil }
        let length = characters.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let info = String(characters.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        return (marker, length, info.isEmpty ? nil : info)
    }

    private static func isClosingFence(_ line: String, matching fence: (character: Character, length: Int, language: String?)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        let length = characters.prefix(while: { $0 == fence.character }).count
        return length >= fence.length && characters.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let markers = line.filter { !$0.isWhitespace }
        guard markers.count >= 3, let first = markers.first else { return false }
        return (first == "-" || first == "_" || first == "*") && markers.allSatisfy { $0 == first }
    }

    private static func isBlockquote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func quotedContent(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func parseListItem(_ line: String) -> MarkdownListItem? {
        let indentation = leadingIndentation(in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        guard !characters.isEmpty else { return nil }

        var markerLength = 0
        if ["-", "+", "*"].contains(String(characters[0])), characters.count > 1, characters[1].isWhitespace {
            markerLength = 1
        } else {
            var digits = 0
            while digits < characters.count, characters[digits].isNumber { digits += 1 }
            if digits > 0,
               digits + 1 < characters.count,
               (characters[digits] == "." || characters[digits] == ")"),
               characters[digits + 1].isWhitespace {
                markerLength = digits + 1
            }
        }
        guard markerLength > 0 else { return nil }

        let marker = String(characters.prefix(markerLength))
        var text = String(characters.dropFirst(markerLength)).trimmingCharacters(in: .whitespaces)
        var renderedMarker = marker == "-" || marker == "+" || marker == "*" ? "•" : marker
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            renderedMarker = "☑"
            text = String(text.dropFirst(4))
        } else if text.hasPrefix("[ ] ") {
            renderedMarker = "☐"
            text = String(text.dropFirst(4))
        }
        return MarkdownListItem(marker: renderedMarker, indentation: indentation, text: text)
    }

    private static func leadingIndentation(in line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(into: 0) { count, character in
            count += character == "\t" ? 4 : 1
        }
    }

    private static func joinParagraphLines(_ lines: [String]) -> String {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    private static func hasUnescapedPipe(_ line: String) -> Bool {
        var isEscaped = false
        for character in line {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "|" {
                return true
            }
        }
        return false
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for character in line {
            if isEscaped {
                if character == "|" {
                    current.append("|")
                } else {
                    current.append("\\")
                    current.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if isEscaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let hyphens = trimmed.filter { $0 == "-" }
            return hyphens.count >= 3 && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
