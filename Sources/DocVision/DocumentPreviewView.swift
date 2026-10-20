import SwiftUI

struct DocumentPreviewView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            documentContent
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("Markdown", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            if let sourceURL = model.sourceURL {
                Text(sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Picker("Режим", selection: binding(\.previewMode)) {
                ForEach(DocumentPreviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            if model.previewMode == .preview {
                Button {
                    model.previewFollowsOutput.toggle()
                } label: {
                    Image(systemName: model.previewFollowsOutput ? "arrow.down.to.line" : "pause")
                }
                .help(model.previewFollowsOutput ? "Прокручивать к последнему результату" : "Остановить автопрокрутку")
            }

            Button(action: model.saveMarkdown) {
                Label("Сохранить", systemImage: "square.and.arrow.down")
            }
            .disabled(model.markdownOutput.isEmpty || model.outputURL == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var documentContent: some View {
        switch model.previewMode {
        case .editing:
            TextEditor(text: binding(\.markdownOutput))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .overlay {
                    if model.markdownOutput.isEmpty {
                        Text(model.isConverting ? "Ожидание результата первой страницы…" : "Markdown пока пуст")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
        case .preview:
            if model.markdownOutput.isEmpty {
                ContentUnavailableView(
                    model.isConverting ? "Обработка страниц" : "Документ пока пуст",
                    systemImage: model.isConverting ? "hourglass" : "doc.text",
                    description: Text(model.status)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(renderedMarkdown)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                        Color.clear.frame(height: 1).id("preview-end")
                    }
                    .onChange(of: model.markdownOutput) { _, _ in
                        guard model.previewFollowsOutput else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("preview-end", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isConverting {
                ProgressView(value: model.progress).frame(width: 120)
                ProgressView().controlSize(.small)
            } else if !model.markdownOutput.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(model.errorMessage ?? model.status)
                .font(.caption)
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(1)
            Spacer()
            if model.isConverting {
                Button("Отменить", action: model.cancelConversion)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var renderedMarkdown: AttributedString {
        (try? AttributedString(markdown: model.markdownOutput)) ?? AttributedString(model.markdownOutput)
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }
}
