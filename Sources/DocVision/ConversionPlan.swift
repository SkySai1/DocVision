import Foundation

enum SourceDocumentType: String {
    case pdf

    static func detect(pathExtension: String) -> SourceDocumentType? {
        SourceDocumentType(rawValue: pathExtension.lowercased())
    }
}

enum ConversionPlan {
    /// Returns zero-based page indexes, grouped in the requested request size.
    static func pageBatches(pageCount: Int, pageLimit: Int, batchSize: Int) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        let count = pageLimit <= 0 ? pageCount : min(pageCount, pageLimit)
        let size = max(1, batchSize)
        return stride(from: 0, to: count, by: size).map { start in
            Array(start..<min(start + size, count))
        }
    }

    /// Applies the configured output-token budget to each page in a request.
    static func responseTokenLimit(perPage: Int, pageCount: Int) -> Int {
        let tokenLimit = max(128, perPage)
        let pages = max(1, pageCount)
        let (scaledLimit, overflow) = tokenLimit.multipliedReportingOverflow(by: pages)
        return overflow ? Int.max : scaledLimit
    }
}
