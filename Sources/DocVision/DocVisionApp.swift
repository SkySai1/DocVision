import SwiftUI

@main
struct DocVisionApp: App {
    private let model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 760)
        }
        .windowResizability(.contentSize)

        WindowGroup("Предпросмотр Markdown", id: "document-preview") {
            DocumentPreviewView(model: model)
                .frame(minWidth: 680, minHeight: 560)
        }
    }
}
