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
        precondition(SourceDocumentType.detect(pathExtension: "PDF") == .pdf)
        precondition(SourceDocumentType.detect(pathExtension: "docx") == nil)
        print("DocVision page planning checks passed.")
    }
}
