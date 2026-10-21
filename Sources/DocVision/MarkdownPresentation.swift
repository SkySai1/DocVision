import Foundation

enum MarkdownDisplayMode: String, CaseIterable, Identifiable, Equatable {
    case continuous
    case pages

    var id: String { rawValue }
    var title: String { self == .continuous ? "Сплошной" : "По страницам" }
}

struct MarkdownPageSection: Identifiable, Equatable {
    let id: Int
    let title: String
    let markdown: String
    let metadataLines: [String]
    let wasTruncated: Bool

    var pageRange: ClosedRange<Int>? {
        let prefix: String
        let isRange: Bool
        if title.hasPrefix("Страницы ") {
            prefix = "Страницы "
            isRange = true
        } else if title.hasPrefix("Страница ") {
            prefix = "Страница "
            isRange = false
        } else {
            return nil
        }

        let value = String(title.dropFirst(prefix.count))
        if !isRange, let page = Int(value) { return page...page }
        let bounds = value.split(whereSeparator: { $0 == "–" || $0 == "—" || $0 == "-" })
        guard bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]), first <= last else { return nil }
        return first...last
    }
}

enum MarkdownPresentation {
    private static let pageMarkerPattern = try! NSRegularExpression(
        pattern: #"^\s*<!--\s*(?:(?:docvision)\s*:\s*)?(?:(?:page-range)\s*|(?:страниц(?:а|ы)?|стр\.?|pages?)\s*[:#]?\s*)(\d+)\s*(?:[-–—]\s*(\d+))?[^>]*-->\s*$"#,
        options: [.caseInsensitive]
    )

    static func isMetadataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->")
    }

    static func cleanExport(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var output: [String] = []
        var hasSeenPageMarker = false
        var openFence: (character: Character, length: Int)?

        for index in lines.indices {
            let line = lines[index]
            if let fence = openFence {
                output.append(line)
                if isClosingFence(line, matching: (fence.character, fence.length, nil)) {
                    openFence = nil
                }
                continue
            }
            if let fence = openingFence(in: line) {
                output.append(line)
                openFence = fence
                continue
            }

            if pageMarkerTitle(in: line) != nil {
                hasSeenPageMarker = true
                continue
            }
            if isDocVisionMetadata(line) {
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "---",
               hasSeenPageMarker,
               nextContentIsPageMarker(after: index, in: lines) {
                continue
            }
            output.append(line)
        }

        var cleaned = output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return cleaned
    }

    static func unwrapOuterMarkdownFence(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard let openingIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let fence = markdownFence(in: lines[openingIndex]) else {
            return markdown
        }

        var body = Array(lines.dropFirst(openingIndex + 1))
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            body.removeLast()
        }
        if let closingLine = body.last, isClosingMarkdownFence(closingLine, matching: fence) {
            body.removeLast()
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitResponse(_ markdown: String, for pageNumbers: [Int]) -> [Int: String]? {
        guard !pageNumbers.isEmpty else { return [:] }
        let normalized = unwrapOuterMarkdownFence(markdown)
        let sections = parse(normalized)
        if pageNumbers.count == 1 {
            return [pageNumbers[0]: sections.first?.markdown ?? normalized]
        }

        let markedSections = sections.filter { $0.pageRange != nil }
        if markedSections.count == pageNumbers.count {
            let sortedSections = markedSections.sorted { ($0.pageRange?.lowerBound ?? 0) < ($1.pageRange?.lowerBound ?? 0) }
            let markedPages = sortedSections.compactMap { section -> (Int, String)? in
                guard let range = section.pageRange, range.lowerBound == range.upperBound else { return nil }
                return (range.lowerBound, section.markdown)
            }
            if markedPages.count == pageNumbers.count,
               Set(markedPages.map(\.0)) == Set(pageNumbers) {
                return Dictionary(uniqueKeysWithValues: markedPages)
            }
        }

        let separatorSections = splitAtHorizontalRules(normalized)
        guard separatorSections.count == pageNumbers.count else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(pageNumbers, separatorSections))
    }

    static func replacingPage(
        _ pageNumber: Int,
        with markdown: String,
        wasTruncated: Bool,
        in source: String
    ) -> String {
        var sections = parse(source)
            .filter { !$0.markdown.isEmpty || !$0.metadataLines.isEmpty }
            .flatMap(expandPageRanges)
        let replacement = MarkdownPageSection(
            id: sections.count,
            title: "Страница \(pageNumber)",
            markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            metadataLines: [],
            wasTruncated: wasTruncated
        )

        if let existingIndex = sections.firstIndex(where: { $0.pageRange?.contains(pageNumber) == true }) {
            sections[existingIndex] = replacement
        } else {
            sections.append(replacement)
        }
        sections.sort { lhs, rhs in
            let leftPage = lhs.pageRange?.lowerBound ?? Int.min
            let rightPage = rhs.pageRange?.lowerBound ?? Int.min
            return leftPage == rightPage ? lhs.id < rhs.id : leftPage < rightPage
        }

        return sections.compactMap { section in
            guard let range = section.pageRange else {
                let content = section.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                return content.isEmpty ? nil : content
            }
            let retainedMetadata = section.metadataLines.filter {
                pageMarkerTitle(in: $0) == nil && !$0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveContains("docvision: output-truncated")
                    && !$0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveContains("docvision: page-range")
            }
            var lines = ["<!-- DocVision: page-range \(range.lowerBound)–\(range.upperBound) -->"]
            lines.append(contentsOf: retainedMetadata)
            if !section.markdown.isEmpty { lines.append(section.markdown) }
            if section.wasTruncated {
                lines.append("<!-- DocVision: output-truncated pages \(range.lowerBound)–\(range.upperBound) -->")
            }
            return lines.joined(separator: "\n\n")
        }
        .joined(separator: "\n\n---\n\n")
    }

    static func canReplacePage(_ pageNumber: Int, in source: String) -> Bool {
        guard let section = parse(source).first(where: { $0.pageRange?.contains(pageNumber) == true }),
              let range = section.pageRange else { return true }
        guard range.lowerBound != range.upperBound else { return true }
        return splitAtHorizontalRules(section.markdown).count == pageCount(in: range)
    }

    private static func expandPageRanges(_ section: MarkdownPageSection) -> [MarkdownPageSection] {
        guard let range = section.pageRange, range.lowerBound != range.upperBound else { return [section] }
        let pages = splitAtHorizontalRules(section.markdown)
        guard pages.count == pageCount(in: range) else { return [section] }

        let retainedMetadata = section.metadataLines.filter { line in
            pageMarkerTitle(in: line) == nil &&
                !line.localizedCaseInsensitiveContains("docvision: page-range") &&
                !line.localizedCaseInsensitiveContains("docvision: output-truncated")
        }
        return zip(range, pages).enumerated().map { offset, pair in
            MarkdownPageSection(
                id: section.id + offset,
                title: "Страница \(pair.0)",
                markdown: pair.1,
                metadataLines: retainedMetadata,
                wasTruncated: section.wasTruncated && pair.0 == range.upperBound
            )
        }
    }

    private static func pageCount(in range: ClosedRange<Int>) -> Int {
        range.upperBound - range.lowerBound + 1
    }

    static func parse(_ markdown: String) -> [MarkdownPageSection] {
        var sections: [MarkdownPageSection] = []
        var bodyLines: [String] = []
        var metadataLines: [String] = []
        var currentTitle: String?
        var wasTruncated = false
        var insideCodeFence = false

        func finishSection() {
            guard currentTitle != nil || !bodyLines.allSatisfy({ $0.isEmpty }) || !metadataLines.isEmpty else { return }
            let title = currentTitle ?? (sections.isEmpty ? "Документ" : "Раздел \(sections.count + 1)")
            sections.append(
                MarkdownPageSection(
                    id: sections.count,
                    title: title,
                    markdown: bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    metadataLines: metadataLines,
                    wasTruncated: wasTruncated
                )
            )
            bodyLines = []
            metadataLines = []
            currentTitle = nil
            wasTruncated = false
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            let appMarker = isAppMetadataMarker(line)
            if (!insideCodeFence || appMarker), !isFence, isMetadataLine(line) {
                if let markerTitle = pageMarkerTitle(in: line) {
                    let hasBodyContent = bodyLines.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if hasBodyContent {
                        if appMarker { removeTrailingPageSeparator(from: &bodyLines) }
                        finishSection()
                    }
                    currentTitle = markerTitle
                    if appMarker { insideCodeFence = false }
                }
                metadataLines.append(line)
                if trimmed.localizedCaseInsensitiveContains("docvision: output-truncated") {
                    wasTruncated = true
                }
                continue
            }

            bodyLines.append(line)
            if isFence {
                insideCodeFence.toggle()
            }
        }
        finishSection()

        if sections.isEmpty {
            sections = [
                MarkdownPageSection(id: 0, title: "Документ", markdown: markdown, metadataLines: [], wasTruncated: false)
            ]
        }
        return sections
    }

    private static func removeTrailingPageSeparator(from lines: inout [String]) {
        // App-authored horizontal rules separate batches in the saved Markdown; the preview adds its own divider.
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            lines.removeLast()
        }
    }

    private static func pageMarkerTitle(in line: String) -> String? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = pageMarkerPattern.firstMatch(in: line, range: fullRange),
              let startRange = Range(match.range(at: 1), in: line),
              let startPage = Int(line[startRange]), startPage > 0 else {
            return nil
        }
        let endPage = Range(match.range(at: 2), in: line).flatMap { Int(line[$0]) } ?? startPage
        guard endPage >= startPage else { return nil }
        if endPage == startPage {
            return "Страница \(startPage)"
        }
        return "Страницы \(startPage)–\(endPage)"
    }

    private static func isAppMetadataMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<!-- docvision: page-range") || trimmed.hasPrefix("<!-- docvision: output-truncated")
    }

    private static func isDocVisionMetadata(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("<!-- docvision:")
    }

    private static func nextContentIsPageMarker(after index: Int, in lines: [String]) -> Bool {
        for nextIndex in lines.indices where nextIndex > index {
            let line = lines[nextIndex]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if pageMarkerTitle(in: line) != nil { return true }
            if isDocVisionMetadata(line) { continue }
            if isMetadataLine(line) {
                continue
            }
            return false
        }
        return false
    }

    private static func splitAtHorizontalRules(_ markdown: String) -> [String] {
        var pages: [String] = []
        var current: [String] = []
        var openFence: (character: Character, length: Int)?

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                current.append(line)
                if isClosingFence(line, matching: (fence.character, fence.length, nil)) { openFence = nil }
                continue
            }
            if let fence = openingFence(in: line) {
                openFence = (fence.character, fence.length)
                current.append(line)
            } else if isHorizontalRule(trimmed) {
                pages.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                current = []
            } else {
                current.append(line)
            }
        }
        pages.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        return pages
    }

    private static func openingFence(in line: String) -> (character: Character, length: Int)? {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        guard let marker = characters.first, marker == "`" || marker == "~" else { return nil }
        let length = characters.prefix(while: { $0 == marker }).count
        return length >= 3 ? (marker, length) : nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isClosingFence(_ line: String, matching fence: (character: Character, length: Int, String?)) -> Bool {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        let length = characters.prefix(while: { $0 == fence.character }).count
        return length >= fence.length && characters.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    private static func markdownFence(in line: String) -> (character: Character, length: Int)? {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        guard let marker = characters.first, marker == "`" || marker == "~" else { return nil }
        let length = characters.prefix(while: { $0 == marker }).count
        let language = String(characters.dropFirst(length)).trimmingCharacters(in: .whitespaces).lowercased()
        guard length >= 3, language == "markdown" || language == "md" else { return nil }
        return (marker, length)
    }

    private static func isClosingMarkdownFence(_ line: String, matching fence: (character: Character, length: Int)) -> Bool {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        let length = characters.prefix(while: { $0 == fence.character }).count
        return length >= fence.length && characters.dropFirst(length).allSatisfy(\.isWhitespace)
    }
}
