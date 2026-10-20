import SwiftUI

struct ContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    documentSection
                    outputStorageSection
                    serverSection
                    conversionSection
                    promptSection
                }
                .padding(22)
            }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.refreshModels() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("DocVision").font(.title2.bold())
                Text("Конвертация PDF в Markdown с помощью VL-моделей")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openWindow(id: "document-preview")
            } label: {
                Label("Просмотр документа", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(model.markdownOutput.isEmpty && !model.isConverting)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(.bar)
    }

    private var documentSection: some View {
        GroupBox("Документ и назначение") {
            VStack(spacing: 12) {
                HStack {
                    Label("Исходный PDF", systemImage: "doc.richtext")
                    Spacer()
                    Text(model.sourceURL?.lastPathComponent ?? "Файл не выбран")
                        .foregroundStyle(.secondary).lineLimit(1)
                    Button("Выбрать…", action: model.choosePDF)
                        .disabled(model.isConverting)
                }
                Divider()
                HStack {
                    Label("Формат", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Picker("Формат", selection: .constant("Markdown")) {
                        Text("Markdown (.md)").tag("Markdown")
                    }
                    .labelsHidden().frame(width: 210).disabled(true)
                }
                HStack {
                    Label("Файл результата", systemImage: "doc.text")
                    Spacer()
                    Text(model.outputURL?.lastPathComponent ?? "Автоматически по имени PDF")
                        .foregroundStyle(.secondary).lineLimit(1)
                    Button("Путь…", action: model.chooseOutput)
                        .disabled(model.isConverting)
                }
                if model.sourcePageCount > 0 {
                    Text("В документе \(model.sourcePageCount) стр. · 0 в лимите означает все страницы")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
        }
    }

    private var serverSection: some View {
        GroupBox("OpenAI-совместимый сервер") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("API URL").frame(width: 115, alignment: .leading)
                    TextField("http://localhost:11436/v1", text: binding(\.endpoint))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.refreshModels()
                    } label: {
                        if model.isLoadingModels { ProgressView().controlSize(.small) }
                        else { Label("Загрузить модели", systemImage: "arrow.clockwise") }
                    }
                    .disabled(model.isLoadingModels)
                }
                HStack {
                    Text("API key").frame(width: 115, alignment: .leading)
                    SecureField("Необязательно для локального сервера", text: binding(\.apiKey))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Модель").frame(width: 115, alignment: .leading)
                    Picker("Модель", selection: binding(\.selectedModel)) {
                        if model.models.isEmpty { Text("Сначала загрузите список").tag("") }
                        ForEach(model.models) { item in Text(item.name).tag(item.id) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    Text("Для изображений требуется VL-модель")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private var outputStorageSection: some View {
        GroupBox("Хранение результатов") {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.outputDirectory.path)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("По умолчанию: ~/.docvision/results · папка запоминается на этом Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Выбрать папку…", action: model.chooseOutputDirectory)
                    .disabled(model.isConverting)
            }
            .padding(.top, 6)
        }
    }

    private var conversionSection: some View {
        GroupBox("Параметры конвертации") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    settingField("Страниц", hint: "0 — все", value: binding(\.pageLimit), width: 100)
                    settingField("Страниц за запрос", hint: "1–8", value: binding(\.pagesPerRequest), width: 100)
                    settingField("Таймаут, сек", hint: "5–1800", value: binding(\.timeoutSeconds), width: 100)
                    settingField("Лимит ответа, токены", hint: "128+", value: binding(\.maxTokens), width: 115)
                }
            }
            .padding(.top, 6)
            Text("Большие пакеты экономят запросы, но требуют больше памяти контекста модели.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private var promptSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Системный промт", systemImage: "text.alignleft").font(.headline)
                    Spacer()
                    Button("Восстановить исходный", action: model.restorePrompt)
                        .controlSize(.small)
                }
                TextEditor(text: binding(\.systemPrompt))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
                    .frame(minHeight: 145)
                Text("Промт сохраняется на этом Mac и отправляется модели для каждого пакета страниц.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.isConverting { ProgressView(value: model.progress).tint(.indigo) }
            HStack(spacing: 12) {
                if model.isConverting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                }
                Text(model.errorMessage ?? model.status)
                    .font(.callout).foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if model.isConverting {
                    Button("Отменить", action: model.cancelConversion)
                }
                Button {
                    model.startConversion()
                    if model.isConverting {
                        openWindow(id: "document-preview")
                    }
                } label: {
                    Label("Конвертировать", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isConverting || model.sourceURL == nil || model.selectedModel.isEmpty)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(.bar)
    }

    private func settingField(_ title: String, hint: String, value: Binding<Int>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: width)
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }
}
