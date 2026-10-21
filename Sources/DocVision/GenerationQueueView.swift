import SwiftUI

struct GenerationQueueView: View {
    let workspace: AppWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                concurrencyControl
                Divider()
                if workspace.jobs.isEmpty {
                    ContentUnavailableView(
                        "Очередь пуста",
                        systemImage: "text.badge.checkmark",
                        description: Text("Добавьте документ или перегенерируйте страницу из окна просмотра.")
                    )
                } else {
                    List(workspace.orderedJobs) { job in
                        queueRow(job)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Очередь генерации")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Очистить завершённые", action: workspace.clearFinishedJobs)
                        .disabled(!workspace.jobs.contains { !$0.status.isPending })
                }
            }
        }
    }

    private var concurrencyControl: some View {
        HStack(spacing: 16) {
            Label("Активно: \(workspace.activeRequestCount) / \(workspace.maxConcurrentRequests)", systemImage: "square.stack.3d.up")
                .font(.headline)
            Stepper(
                "Запросов: \(workspace.maxConcurrentRequests)",
                value: Binding(
                    get: { workspace.maxConcurrentRequests },
                    set: { workspace.maxConcurrentRequests = $0 }
                ),
                in: 1...4
            )
            .frame(width: 220)
            Text("Можно обрабатывать страницы одного документа параллельно")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private func queueRow(_ job: GenerationQueueItem) -> some View {
        HStack(spacing: 12) {
            Button {
                if let model = workspace.sessions[job.sessionID] {
                    model.selectPage(job.pageNumber)
                    openWindow(id: "document-preview", value: job.sessionID)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(workspace.sessionTitle(for: job.sessionID)) · страница \(job.pageNumber)")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(job.status.title)
                        .font(.caption)
                        .foregroundStyle(statusColor(job.status))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Перейти к странице в предпросмотре")

            if job.status == .queued {
                Stepper(
                    "Приоритет \(job.priority)",
                    value: Binding(
                        get: { workspace.jobs.first(where: { $0.id == job.id })?.priority ?? job.priority },
                        set: { workspace.setPriority(job.id, to: $0) }
                    ),
                    in: -100...100
                )
                .labelsHidden()
                .help("Приоритет от −100 до 100. Задачи с большим числом запускаются раньше.")
                Text("\(job.priority)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
                    .help("Приоритет: \(job.priority)")
                Button {
                    workspace.cancelQueuedJob(job.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Убрать страницу из очереди")
            } else if job.status == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: job.status == .completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(statusColor(job.status))
                    .frame(width: 20)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: GenerationQueueStatus) -> Color {
        switch status {
        case .queued: .secondary
        case .running: .blue
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        }
    }
}
