import Foundation
import Observation

enum GenerationQueueStatus: Equatable {
    case queued
    case running
    case completed
    case failed(String)
    case cancelled

    var isPending: Bool {
        switch self {
        case .queued, .running: true
        case .completed, .failed, .cancelled: false
        }
    }

    var title: String {
        switch self {
        case .queued: "В очереди"
        case .running: "Генерируется"
        case .completed: "Готово"
        case .failed(let message): "Ошибка: \(message)"
        case .cancelled: "Отменено"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct GenerationQueueItem: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let pageNumber: Int
    let sequence: Int
    var priority: Int
    var status: GenerationQueueStatus
}

@MainActor
@Observable
final class AppWorkspace {
    var sessions: [UUID: AppModel] = [:]
    var jobs: [GenerationQueueItem] = []
    var maxConcurrentRequests: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrentRequests, forKey: "maxConcurrentRequests")
            schedule()
        }
    }
    private(set) var activeRequestCount = 0

    @ObservationIgnored private var nextSequence = 0
    @ObservationIgnored private var activeRequests: [UUID: ActiveRequest] = [:]

    private struct ActiveRequest {
        let sessionID: UUID
        let task: Task<Void, Never>
    }

    init() {
        let storedLimit = (UserDefaults.standard.object(forKey: "maxConcurrentRequests") as? Int)
            ?? UserDefaults.standard.integer(forKey: "maxConcurrentSessions").nonzeroOr(2)
        maxConcurrentRequests = min(4, max(1, storedLimit))
    }

    func createSession() -> UUID {
        let id = UUID()
        sessions[id] = AppModel(sessionID: id, workspace: self)
        return id
    }

    func enqueue(_ model: AppModel, pageNumbers: [Int], priority: Int = 0) {
        guard !pageNumbers.isEmpty else {
            model.queueDidFinish()
            return
        }
        for pageNumber in pageNumbers {
            jobs.append(
                GenerationQueueItem(
                    id: UUID(),
                    sessionID: model.sessionID,
                    pageNumber: pageNumber,
                    sequence: nextSequence,
                    priority: priority,
                    status: .queued
                )
            )
            nextSequence += 1
            model.pageStatuses[pageNumber] = .queued
        }
        model.queueDidStart(pageNumbers: pageNumbers)
        schedule()
    }

    func setPriority(_ jobID: UUID, to priority: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .queued else { return }
        jobs[index].priority = min(100, max(-100, priority))
        schedule()
    }

    func cancelQueuedJob(_ jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .queued else { return }
        jobs[index].status = .cancelled
        sessions[jobs[index].sessionID]?.pageStatuses[jobs[index].pageNumber] = .cancelled
        finishSessionIfIdle(jobs[index].sessionID)
        schedule()
    }

    func cancelSession(_ sessionID: UUID) {
        for index in jobs.indices where jobs[index].sessionID == sessionID && jobs[index].status == .queued {
            jobs[index].status = .cancelled
            sessions[sessionID]?.pageStatuses[jobs[index].pageNumber] = .cancelled
        }
        for request in activeRequests.values where request.sessionID == sessionID {
            request.task.cancel()
        }
        finishSessionIfIdle(sessionID)
        schedule()
    }

    func clearFinishedJobs() {
        jobs.removeAll { !$0.status.isPending }
    }

    func activeRequestCount(for sessionID: UUID) -> Int {
        activeRequests.values.filter { $0.sessionID == sessionID }.count
    }

    var orderedJobs: [GenerationQueueItem] {
        jobs.sorted { lhs, rhs in
            if lhs.status.isPending != rhs.status.isPending { return lhs.status.isPending }
            if lhs.status == .queued, rhs.status == .queued, lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.sequence < rhs.sequence
        }
    }

    func sessionTitle(for id: UUID) -> String {
        guard let model = sessions[id] else { return "Закрытый сеанс" }
        let title = model.sourceURL?.lastPathComponent ?? "Новый сеанс"
        let sameTitleCount = sessions.values.filter { $0.sourceURL?.lastPathComponent == title }.count
        return sameTitleCount > 1 ? "\(title) · \(id.uuidString.prefix(4))" : title
    }

    func uniqueOutputURL(for model: AppModel, proposed: URL) -> URL {
        let destination = proposed.standardizedFileURL
        let conflictsWithActiveSession = sessions.values.contains { other in
            other.sessionID != model.sessionID && other.isConverting &&
                other.outputURL?.standardizedFileURL == destination
        }
        guard conflictsWithActiveSession else { return proposed }

        let baseName = destination.deletingPathExtension().lastPathComponent
        let fileExtension = destination.pathExtension.isEmpty ? "md" : destination.pathExtension
        var suffix = 2
        while true {
            let candidate = destination.deletingLastPathComponent()
                .appendingPathComponent("\(baseName) (\(suffix))")
                .appendingPathExtension(fileExtension)
            let isUsedByActiveSession = sessions.values.contains { other in
                other.sessionID != model.sessionID && other.isConverting &&
                    other.outputURL?.standardizedFileURL == candidate.standardizedFileURL
            }
            if !isUsedByActiveSession { return candidate }
            suffix += 1
        }
    }

    private func schedule() {
        while activeRequests.count < maxConcurrentRequests {
            let candidate = jobs
                .filter { $0.status == .queued }
                .sorted { lhs, rhs in
                    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                    return lhs.sequence < rhs.sequence
                }
                .first
            guard let candidate, let model = sessions[candidate.sessionID] else { return }

            let batchSize = max(1, model.pagesPerRequest)
            var batch = [candidate]
            var nextPage = candidate.pageNumber + 1
            while batch.count < batchSize,
                  let next = jobs.first(where: {
                      $0.status == .queued && $0.sessionID == candidate.sessionID &&
                      $0.priority == candidate.priority && $0.pageNumber == nextPage
                  }) {
                batch.append(next)
                nextPage += 1
            }

            let batchIDs = Set(batch.map(\.id))
            let pageNumbers = batch.map(\.pageNumber)
            for index in jobs.indices where batchIDs.contains(jobs[index].id) {
                jobs[index].status = .running
                model.pageStatuses[jobs[index].pageNumber] = .running
            }
            let sessionID = candidate.sessionID
            let requestID = UUID()
            let task = Task { @MainActor [weak self, model] in
                let successfulPages = await model.processPages(pageNumbers)
                self?.complete(
                    requestID: requestID,
                    sessionID: sessionID,
                    jobIDs: batchIDs,
                    successfulPages: successfulPages
                )
            }
            activeRequests[requestID] = ActiveRequest(sessionID: sessionID, task: task)
            activeRequestCount = activeRequests.count
        }
    }

    private func complete(requestID: UUID, sessionID: UUID, jobIDs: Set<UUID>, successfulPages: Set<Int>) {
        for index in jobs.indices where jobIDs.contains(jobs[index].id) {
            if successfulPages.contains(jobs[index].pageNumber) {
                jobs[index].status = .completed
            } else if jobs[index].status == .cancelled {
                continue
            } else if let status = sessions[sessionID]?.pageStatuses[jobs[index].pageNumber],
                      let message = status.failureMessage {
                jobs[index].status = .failed(message)
            } else {
                jobs[index].status = .cancelled
            }
        }
        activeRequests[requestID] = nil
        activeRequestCount = activeRequests.count
        finishSessionIfIdle(sessionID)
        schedule()
    }

    private func finishSessionIfIdle(_ sessionID: UUID) {
        let hasPending = jobs.contains { $0.sessionID == sessionID && $0.status.isPending }
        guard !hasPending else { return }
        sessions[sessionID]?.queueDidFinish()
    }
}

private extension Int {
    func nonzeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
