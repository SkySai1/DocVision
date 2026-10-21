import SwiftUI

struct DocumentPreviewView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            previewLayout
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Markdown", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)
                if let sourceURL = model.sourceURL {
                    Text(sourceURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                }
                Spacer(minLength: 8)
                Picker("Режим", selection: binding(\.previewMode)) {
                    ForEach(DocumentPreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Режим")
                .frame(width: 210)

                if model.previewMode == .preview {
                    Button {
                        model.previewFollowsOutput.toggle()
                    } label: {
                        Image(systemName: model.previewFollowsOutput ? "arrow.down.to.line" : "pause")
                    }
                    .accessibilityLabel(model.previewFollowsOutput ? "Прокручивать к последнему результату" : "Остановить автопереход к новому результату")
                    .help(model.previewFollowsOutput ? "Прокручивать к последнему результату" : "Остановить автопереход к новому результату")

                    if model.sourceURL != nil {
                        Button {
                            model.isThumbnailSidebarVisible.toggle()
                        } label: {
                            Image(systemName: model.isThumbnailSidebarVisible ? "sidebar.left" : "sidebar.right")
                        }
                        .accessibilityLabel(model.isThumbnailSidebarVisible ? "Скрыть миниатюры страниц" : "Показать миниатюры страниц")
                        .help(model.isThumbnailSidebarVisible ? "Скрыть миниатюры страниц" : "Показать миниатюры страниц")
                    }
                }

                Button(action: model.saveMarkdown) {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Сохранить Markdown")
                .help(model.outputURL == nil ? "Экспортировать Markdown в выбранный файл" : "Сохранить Markdown")
                .disabled(model.markdownOutput.isEmpty)
            }

            if model.previewMode == .preview {
                HStack(spacing: 8) {
                    Text("Отображение страниц")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Picker("Отображение страниц", selection: binding(\.markdownDisplayMode)) {
                        ForEach(MarkdownDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)

                    if model.markdownDisplayMode == .pages {
                        pageNavigation
                    }

                    Spacer(minLength: 0)
                    Toggle(isOn: binding(\.showMarkdownMetadataMarkers)) {
                        Label("Маркеры", systemImage: model.showMarkdownMetadataMarkers ? "eye" : "eye.slash")
                    }
                    .toggleStyle(.button)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Показывать или скрывать служебные комментарии. При показе они выделены цветом.")
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "highlighter")
                    Text("Служебные маркеры остаются в исходном Markdown и подсвечены в редакторе.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var pageNavigation: some View {
        let sections = parsedSections
        HStack(spacing: 8) {
            Button {
                selectSection(at: max(0, model.markdownSelectedSectionIndex - 1))
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.markdownSelectedSectionIndex <= 0)
            .help("Предыдущая страница")

            if sections.indices.contains(model.markdownSelectedSectionIndex) {
                Text("\(model.markdownSelectedSectionIndex + 1) из \(sections.count) · \(sections[model.markdownSelectedSectionIndex].title)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 104, alignment: .center)
                    .help(sections[model.markdownSelectedSectionIndex].title)
            } else {
                Text("Нет страниц")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                selectSection(at: min(max(0, sections.count - 1), model.markdownSelectedSectionIndex + 1))
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.markdownSelectedSectionIndex >= sections.count - 1)
            .help("Следующая страница")
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var previewLayout: some View {
        if model.previewMode == .preview, model.isThumbnailSidebarVisible, model.sourceURL != nil {
            HStack(spacing: 0) {
                PageThumbnailSidebar(model: model)
                    .frame(width: 174)
                Divider()
                documentContent
            }
        } else {
            documentContent
        }
    }

    @ViewBuilder
    private var documentContent: some View {
        switch model.previewMode {
        case .editing:
            MarkdownSourceEditor(text: binding(\.markdownOutput), highlightsMetadata: true)
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
                        if model.markdownDisplayMode == .continuous {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(parsedSections) { section in
                                    renderedSection(section, showTitle: false)
                                    if section.id < parsedSections.count - 1 {
                                        Divider()
                                    }
                                }
                                Color.clear.frame(height: 1).id("preview-end")
                            }
                            .padding(24)
                        } else if let section = selectedSection {
                            renderedSection(section, showTitle: true)
                                .id(section.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(24)
                        } else if let selectedPageNumber = model.selectedPageNumber {
                            ContentUnavailableView(
                                "Страница \(selectedPageNumber) ещё не сгенерирована",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("Нажмите кнопку перегенерации в списке миниатюр, чтобы добавить эту страницу в очередь.")
                            )
                        }
                    }
                    .onChange(of: model.markdownOutput) { _, _ in
                        let latestIndex = max(0, parsedSections.count - 1)
                        if model.markdownDisplayMode == .pages && model.previewFollowsOutput {
                            model.markdownSelectedSectionIndex = latestIndex
                            model.selectedPageNumber = parsedSections.indices.contains(latestIndex)
                                ? parsedSections[latestIndex].pageRange?.lowerBound
                                : nil
                        }
                        guard model.previewFollowsOutput else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            if model.markdownDisplayMode == .continuous {
                                proxy.scrollTo("preview-end", anchor: .bottom)
                            } else {
                                proxy.scrollTo(latestIndex, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: model.markdownDisplayMode) { _, newMode in
                        guard newMode == .pages, !parsedSections.isEmpty else { return }
                        model.markdownSelectedSectionIndex = min(model.markdownSelectedSectionIndex, parsedSections.count - 1)
                    }
                }
            }
        }
    }

    private var parsedSections: [MarkdownPageSection] {
        MarkdownPresentation.parse(model.markdownOutput)
    }

    private var selectedSection: MarkdownPageSection? {
        let sections = parsedSections
        if let selectedPageNumber = model.selectedPageNumber {
            return sections.first(where: { $0.pageRange?.contains(selectedPageNumber) == true })
        }
        guard sections.indices.contains(model.markdownSelectedSectionIndex) else { return sections.first }
        return sections[model.markdownSelectedSectionIndex]
    }

    private func selectSection(at index: Int) {
        let sections = parsedSections
        guard sections.indices.contains(index) else { return }
        model.markdownSelectedSectionIndex = index
        model.selectedPageNumber = sections[index].pageRange?.lowerBound
    }

    @ViewBuilder
    private func renderedSection(_ section: MarkdownPageSection, showTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showTitle {
                Text(section.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if section.wasTruncated {
                Label("Ответ остановлен на лимите токенов. Конец \(section.title.lowercased()) может быть неполным.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.showMarkdownMetadataMarkers {
                ForEach(Array(section.metadataLines.enumerated()), id: \.offset) { marker in
                    highlightedMetadataLine(marker.element)
                }
            }

            if !section.markdown.isEmpty {
                MarkdownRenderedView(markdown: section.markdown)
            }
        }
    }

    private func highlightedMetadataLine(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.orange.opacity(0.28)))
            .textSelection(.enabled)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isConverting {
                ProgressView(value: model.progress).frame(width: 84)
                ProgressView().controlSize(.small)
            } else if !model.markdownOutput.isEmpty {
                Image(systemName: parsedSections.contains(where: \.wasTruncated) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(parsedSections.contains(where: \.wasTruncated) ? Color.orange : Color.green)
            }
            diagnosticsSummary
            Text(model.errorMessage ?? model.status)
                .font(.caption)
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer()
            if model.isConverting {
                Button("Отменить", action: model.cancelConversion)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var diagnosticsSummary: some View {
        let diagnostics = model.lastRequestDiagnostics
        let contextSize = model.serverContextWindow
        let contextUsed = model.liveContextTokens ?? diagnostics?.contextTokensUsed

        if diagnostics != nil || contextSize != nil {
            HStack(spacing: 7) {
                if let generatedTokens = diagnostics?.generatedTokens {
                    Text("посл. \(generatedTokens) ток")
                        .help(diagnosticsDescription(diagnostics))
                }
                if let speed = diagnostics?.generationTokensPerSecond, speed.isFinite, speed > 0 {
                    Text("\(Int(speed.rounded())) ток/с")
                        .help(diagnosticsDescription(diagnostics))
                }
                if let contextSize, contextSize > 0, let contextUsed {
                    let percentage = Int((Double(contextUsed) / Double(contextSize) * 100).rounded())
                    Text("\(model.liveContextTokens == nil ? "" : "~")\(percentage)% конт.")
                        .help("Контекст: \(contextUsed) из \(contextSize) токенов. Тильда означает текущую оценку слота llama-server.")
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        } else if model.isConverting {
            Text("Сбор статистики…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func diagnosticsDescription(_ diagnostics: GenerationDiagnostics?) -> String {
        guard let diagnostics else { return "Статистика последнего запроса" }
        var details: [String] = []
        if let promptTokens = diagnostics.promptTokens { details.append("Вход: \(promptTokens) токенов") }
        if let cachedTokens = diagnostics.cachedPromptTokens, cachedTokens > 0 {
            details.append("Из кэша: \(cachedTokens) токенов")
        }
        if let generatedTokens = diagnostics.generatedTokens { details.append("Сгенерировано: \(generatedTokens) токенов") }
        if let speed = diagnostics.promptTokensPerSecond, speed.isFinite {
            details.append("Скорость обработки входа: \(Int(speed.rounded())) ток/с")
        }
        if let speed = diagnostics.generationTokensPerSecond, speed.isFinite {
            details.append("Скорость генерации: \(Int(speed.rounded())) ток/с")
        }
        if let milliseconds = diagnostics.promptMilliseconds {
            details.append("Время обработки входа: \(Int(milliseconds.rounded())) мс")
        }
        if let milliseconds = diagnostics.generationMilliseconds {
            details.append("Время генерации: \(Int(milliseconds.rounded())) мс")
        }
        return "Статистика последней итерации. " + details.joined(separator: " · ")
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }
}
