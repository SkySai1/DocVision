import Foundation

enum RequestTimeoutMode: String, CaseIterable, Identifiable {
    case hard
    case soft

    var id: String { rawValue }
    var title: String { self == .hard ? "Жёсткий" : "Мягкий" }
}

struct AvailableModel: Decodable, Identifiable, Hashable {
    let id: String
    var name: String { id }
}

struct GenerationDiagnostics: Equatable {
    let promptTokens: Int?
    let cachedPromptTokens: Int?
    let generatedTokens: Int?
    let contextTokensUsed: Int?
    let promptTokensPerSecond: Double?
    let generationTokensPerSecond: Double?
    let promptMilliseconds: Double?
    let generationMilliseconds: Double?
}

struct ConversionResponse {
    let markdown: String
    let diagnostics: GenerationDiagnostics
    let finishReason: String?

    var wasTruncated: Bool {
        ["length", "max_tokens", "max_output_tokens"].contains(finishReason?.lowercased() ?? "")
    }
}

struct ModelSlotSnapshot {
    let contextSize: Int
    let contextTokensUsed: Int
    let isProcessing: Bool
}

private struct ModelListResponse: Decodable {
    let data: [AvailableModel]
}

struct OpenAICompatibleClient {
    let baseURL: URL
    let apiKey: String
    let timeout: TimeInterval

    func fetchModels() async throws -> [AvailableModel] {
        let request = try makeRequest(path: "models", method: "GET")
        let (data, response) = try await data(for: request, hardTimeout: timeout)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ModelListResponse.self, from: data).data.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    func keepalive() async throws {
        let request = try makeRequest(path: "models", method: "GET")
        let (_, response) = try await data(for: request, hardTimeout: timeout)
        guard response is HTTPURLResponse else {
            throw ClientError.invalidResponse("Keepalive не получил HTTP-ответ от сервера.")
        }
    }

    func convert(
        systemPrompt: String,
        instruction: String,
        images: [String],
        model: String,
        maxTokens: Int,
        timeoutMode: RequestTimeoutMode = .hard
    ) async throws -> ConversionResponse {
        let requestTimeout: TimeInterval? = timeoutMode == .soft ? max(86_400, timeout) : nil
        var request = try makeRequest(path: "chat/completions", method: "POST", timeoutOverride: requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeConversionBody(
            systemPrompt: systemPrompt,
            instruction: instruction,
            images: images,
            model: model,
            maxTokens: maxTokens
        )
        let (data, response) = try await data(
            for: request,
            hardTimeout: timeoutMode == .hard ? timeout : nil
        )
        try validate(response: response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let choice = choices?.first
        let message = choice?["message"] as? [String: Any]
        let markdown: String
        if let text = message?["content"] as? String {
            markdown = text
        } else if let parts = message?["content"] as? [[String: Any]] {
            markdown = parts.compactMap { $0["text"] as? String }.joined()
        } else {
            throw ClientError.invalidResponse("Ответ модели не содержит текст.")
        }

        let usage = json?["usage"] as? [String: Any]
        let promptDetails = usage?["prompt_tokens_details"] as? [String: Any]
        let timings = json?["timings"] as? [String: Any]
        let timedPromptTokens = Self.integer(timings?["prompt_n"])
        let timedCachedTokens = Self.integer(timings?["cache_n"])
        let timedGeneratedTokens = Self.integer(timings?["predicted_n"])
        let usagePromptTokens = Self.integer(usage?["prompt_tokens"])
        let usageGeneratedTokens = Self.integer(usage?["completion_tokens"])
        let diagnostics = GenerationDiagnostics(
            promptTokens: timedPromptTokens ?? usagePromptTokens,
            cachedPromptTokens: timedCachedTokens ?? Self.integer(promptDetails?["cached_tokens"]),
            generatedTokens: timedGeneratedTokens ?? usageGeneratedTokens,
            contextTokensUsed: timedPromptTokens.flatMap { prompt in
                timedGeneratedTokens.map { prompt + (timedCachedTokens ?? 0) + $0 }
            } ?? usagePromptTokens.flatMap { prompt in usageGeneratedTokens.map { prompt + $0 } },
            promptTokensPerSecond: Self.decimal(timings?["prompt_per_second"]),
            generationTokensPerSecond: Self.decimal(timings?["predicted_per_second"]),
            promptMilliseconds: Self.decimal(timings?["prompt_ms"]),
            generationMilliseconds: Self.decimal(timings?["predicted_ms"])
        )
        return ConversionResponse(
            markdown: markdown,
            diagnostics: diagnostics,
            finishReason: choice?["finish_reason"] as? String
        )
    }

    static func makeConversionBody(
        systemPrompt: String,
        instruction: String,
        images: [String],
        model: String,
        maxTokens: Int
    ) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": instruction]]
        for image in images {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,\(image)"]
            ])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": content]
            ],
            "max_tokens": max(128, maxTokens),
            "temperature": 0
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    func fetchSlotSnapshot(model: String) async -> ModelSlotSnapshot? {
        guard let request = makeSlotRequest(model: model),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let slots = try? JSONDecoder().decode([SlotResponse].self, from: data),
              let slot = slots.first,
              let contextSize = slot.contextSize,
              contextSize > 0 else {
            return nil
        }

        let generatedTokens = slot.nextToken?.first?.decodedTokens ?? 0
        return ModelSlotSnapshot(
            contextSize: contextSize,
            contextTokensUsed: max(0, (slot.promptTokens ?? 0) + generatedTokens),
            isProcessing: slot.isProcessing ?? false
        )
    }

    private func makeRequest(path: String, method: String, timeoutOverride: TimeInterval? = nil) throws -> URLRequest {
        let normalized = baseURL.absoluteString.hasSuffix("/") ? baseURL : URL(string: baseURL.absoluteString + "/")!
        guard let url = URL(string: path, relativeTo: normalized)?.absoluteURL else {
            throw ClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: max(1, timeoutOverride ?? timeout))
        request.httpMethod = method
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func data(for request: URLRequest, hardTimeout: TimeInterval?) async throws -> (Data, URLResponse) {
        guard let hardTimeout else {
            return try await URLSession.shared.data(for: request)
        }

        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(hardTimeout))
                throw ClientError.requestTimedOut(hardTimeout)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ClientError.invalidResponse("Запрос завершился без ответа.")
            }
            return result
        }
    }

    private func makeSlotRequest(model: String) -> URLRequest? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var rootPath = components.path
        while rootPath.count > 1 && rootPath.hasSuffix("/") { rootPath.removeLast() }
        if rootPath == "/v1" {
            rootPath = ""
        } else if rootPath.hasSuffix("/v1") {
            rootPath.removeLast(3)
        }
        components.path = rootPath + "/slots"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func decimal(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse("Сервер вернул неизвестный ответ.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpStatus(http.statusCode, String(body.prefix(600)))
        }
    }
}

private struct SlotResponse: Decodable {
    let contextSize: Int?
    let isProcessing: Bool?
    let promptTokens: Int?
    let nextToken: [NextTokenResponse]?

    enum CodingKeys: String, CodingKey {
        case contextSize = "n_ctx"
        case isProcessing = "is_processing"
        case promptTokens = "n_prompt_tokens"
        case nextToken = "next_token"
    }
}

private struct NextTokenResponse: Decodable {
    let decodedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case decodedTokens = "n_decoded"
    }
}

enum ClientError: LocalizedError {
    case invalidEndpoint
    case invalidResponse(String)
    case httpStatus(Int, String)
    case requestTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Некорректный URL API. Укажите адрес сервера, например http://localhost:11436/v1."
        case .invalidResponse(let message):
            return message
        case .httpStatus(let status, let detail):
            return detail.isEmpty ? "Ошибка API (HTTP \(status))." : "Ошибка API (HTTP \(status)): \(detail)"
        case .requestTimedOut(let seconds):
            return "Запрос не завершился за \(Int(seconds)) сек."
        }
    }
}
