import Foundation

struct OllamaModel: Identifiable, Decodable, Hashable {
    struct Details: Decodable, Hashable {
        let family: String?
        let parameterSize: String?

        enum CodingKeys: String, CodingKey {
            case family
            case parameterSize = "parameter_size"
        }
    }

    let name: String
    let modifiedAt: String?
    let size: Int?
    let details: Details?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
        case details
    }
}

final class OllamaService {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func listModels() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        struct TagsResponse: Decodable {
            let models: [OllamaModel]
        }

        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func chat(model: String, messages: [ConversationMessage]) async throws -> String {
        let request = try buildChatRequest(model: model, messages: messages, stream: false)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        struct ChatResponse: Decodable {
            struct Message: Decodable {
                let role: String
                let content: String
            }

            let message: Message
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chatStream(
        model: String,
        messages: [ConversationMessage],
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws {
        let request = try buildChatRequest(model: model, messages: messages, stream: true)
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaError.server(statusCode: http.statusCode, body: "Streaming request failed")
        }

        struct StreamChunk: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let done: Bool?
            let message: Message?
            let error: String?
        }

        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let data = Data(trimmed.utf8)
            let chunk = try JSONDecoder().decode(StreamChunk.self, from: data)

            if let error = chunk.error {
                throw OllamaError.server(statusCode: http.statusCode, body: error)
            }

            if let piece = chunk.message?.content, !piece.isEmpty {
                await onDelta(piece)
            }

            if chunk.done == true {
                return
            }
        }
    }

    private func buildChatRequest(model: String, messages: [ConversationMessage], stream: Bool) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        struct ChatBody: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }

            let model: String
            let messages: [Message]
            let stream: Bool
            let options: [String: Double]
        }

        let body = ChatBody(
            model: model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.text) },
            stream: stream,
            options: ["temperature": 0.8]
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            throw OllamaError.server(statusCode: http.statusCode, body: body)
        }
    }
}

enum OllamaError: LocalizedError {
    case invalidResponse
    case server(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Ollama returned an invalid response."
        case let .server(statusCode, body):
            return "Ollama error \(statusCode): \(body)"
        }
    }
}
