import AppKit
import Foundation
import PDFKit

@main
enum PDFSampleSmokeChecks {
    static func main() throws {
        let sampleDirectory = URL(fileURLWithPath: "Samples", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sampleDirectory, includingPropertiesForKeys: nil)
            .filter { SourceDocumentType.detect(pathExtension: $0.pathExtension) == .pdf }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        precondition(!files.isEmpty, "No PDF examples were found in Samples/")

        for file in files {
            guard let document = PDFDocument(url: file), document.pageCount > 0,
                  let page = document.page(at: 0) else {
                fatalError("Could not open PDF sample: \(file.lastPathComponent)")
            }
            let thumbnail = page.thumbnail(of: NSSize(width: 800, height: 1100), for: .mediaBox)
            guard let tiff = thumbnail.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Could not render first page of \(file.lastPathComponent)")
            }
            precondition(!png.base64EncodedString().isEmpty)
            print("\(file.lastPathComponent): \(document.pageCount) page(s), first page renders to PNG")
        }
    }
}
