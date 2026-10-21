import SwiftUI

@main
struct DocVisionApp: App {
    private let workspace = AppWorkspace()

    var body: some Scene {
        WindowGroup("DocVision", id: "session", for: UUID.self) { sessionID in
            SessionWindowRoot(workspace: workspace, sessionID: sessionID)
                .frame(minWidth: 760, minHeight: 760)
        }
        .windowResizability(.contentSize)

        WindowGroup("Предпросмотр Markdown", id: "document-preview", for: UUID.self) { sessionID in
            PreviewWindowRoot(workspace: workspace, sessionID: sessionID)
                .frame(minWidth: 680, minHeight: 560)
        }
    }
}

private struct SessionWindowRoot: View {
    let workspace: AppWorkspace
    @Binding var sessionID: UUID?

    var body: some View {
        Group {
            if let sessionID, let model = workspace.sessions[sessionID] {
                ContentView(model: model, workspace: workspace)
            } else {
                ProgressView("Создание сеанса…")
            }
        }
        .task {
            if sessionID == nil { sessionID = workspace.createSession() }
        }
    }
}

private struct PreviewWindowRoot: View {
    let workspace: AppWorkspace
    @Binding var sessionID: UUID?

    var body: some View {
        Group {
            if let sessionID, let model = workspace.sessions[sessionID] {
                DocumentPreviewView(model: model)
            } else {
                ContentUnavailableView("Сеанс не найден", systemImage: "doc.questionmark")
            }
        }
    }
}
