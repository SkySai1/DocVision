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
}
