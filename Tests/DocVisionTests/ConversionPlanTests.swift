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

    func testExtensionDetectionIgnoresCaseAndRejectsUnknownTypes() {
        XCTAssertEqual(SourceDocumentType.detect(pathExtension: "PDF"), .pdf)
        XCTAssertNil(SourceDocumentType.detect(pathExtension: "docx"))
    }
}
