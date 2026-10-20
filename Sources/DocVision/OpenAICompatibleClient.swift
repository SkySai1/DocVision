import Foundation

struct AvailableModel: Decodable, Identifiable, Hashable {
    let id: String
    var name: String { id }
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
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ModelListResponse.self, from: data).data.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    func convert(systemPrompt: String, instruction: String, images: [String], model: String, maxTokens: Int) async throws -> String {
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
        var request = try makeRequest(path: "chat/completions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        if let text = message?["content"] as? String { return text }
        if let parts = message?["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        throw ClientError.invalidResponse("Ответ модели не содержит текст.")
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let normalized = baseURL.absoluteString.hasSuffix("/") ? baseURL : URL(string: baseURL.absoluteString + "/")!
        guard let url = URL(string: path, relativeTo: normalized)?.absoluteURL else {
            throw ClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: max(1, timeout))
        request.httpMethod = method
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
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

enum ClientError: LocalizedError {
    case invalidEndpoint
    case invalidResponse(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Некорректный URL API. Укажите адрес сервера, например http://localhost:11436/v1."
        case .invalidResponse(let message):
            return message
        case .httpStatus(let status, let detail):
            return detail.isEmpty ? "Ошибка API (HTTP \(status))." : "Ошибка API (HTTP \(status)): \(detail)"
        }
    }
}
