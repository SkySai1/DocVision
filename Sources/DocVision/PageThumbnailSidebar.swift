import SwiftUI

struct PageThumbnailSidebar: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Страницы")
                    .font(.headline)
                Spacer()
                Text("\(model.documentPageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if model.documentPageCount > 0 {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(1...model.documentPageCount, id: \.self) { pageNumber in
                                thumbnailRow(pageNumber)
                                    .id(pageNumber)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selectedPageNumber) { _, pageNumber in
                        guard let pageNumber else { return }
                        withAnimation(.easeInOut(duration: 0.16)) {
                            proxy.scrollTo(pageNumber, anchor: .center)
                        }
                    }
                    .task {
                        if let pageNumber = model.selectedPageNumber {
                            proxy.scrollTo(pageNumber, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func thumbnailRow(_ pageNumber: Int) -> some View {
        let isSelected = model.selectedPageNumber == pageNumber
        let status = model.pageStatuses[pageNumber]
        let isPending = status == .queued || status == .running

        return HStack(spacing: 7) {
            Button {
                model.selectPage(pageNumber)
            } label: {
                VStack(spacing: 4) {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = model.thumbnail(forPage: pageNumber) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "doc")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(18)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 66, height: 82)
                        .background(.white, in: RoundedRectangle(cornerRadius: 4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.12)))

                        if let status {
                            statusBadge(status)
                                .padding(3)
                        }
                    }
                    Text("\(pageNumber)")
                        .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(5)
                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Перейти к странице \(pageNumber)")

            Button {
                model.selectPage(pageNumber)
                model.regeneratePage(pageNumber)
            } label: {
                Image(systemName: isPending ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(isPending || model.selectedModel.isEmpty || model.sourceURL == nil)
            .help(isPending ? "Страница уже в очереди" : "Перегенерировать страницу \(pageNumber)")
        }
        .padding(3)
    }

    @ViewBuilder
    private func statusBadge(_ status: GenerationQueueStatus) -> some View {
        switch status {
        case .queued:
            Image(systemName: "clock.fill").foregroundStyle(.orange)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}
