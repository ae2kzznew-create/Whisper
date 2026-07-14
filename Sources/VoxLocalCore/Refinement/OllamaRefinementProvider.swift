import Foundation

/// Refines transcripts through a local Ollama server. Privacy guarantee:
/// the endpoint must resolve to a loopback host, otherwise every call fails
/// with `RefinementError.nonLocalEndpoint` — no request leaves the machine.
public final class OllamaRefinementProvider: TextRefinementProvider, @unchecked Sendable {
    public let endpoint: URL
    public let model: String
    private let session: URLSession

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// Refuses every HTTP redirect. Without this, a process answering on
    /// the loopback port could 307-redirect the transcript POST to a remote
    /// host and URLSession would follow it — breaking the privacy guarantee.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil) // deliver the 3xx as-is; never follow
        }
    }

    public init(endpoint: String, model: String, session: URLSession? = nil) throws {
        guard let url = URL(string: endpoint), let host = url.host else {
            throw RefinementError.nonLocalEndpoint(endpoint)
        }
        guard Self.isLoopback(host: host) else {
            throw RefinementError.nonLocalEndpoint(endpoint)
        }
        self.endpoint = url
        self.model = model
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    public static func isLoopback(host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }

    // MARK: - Availability

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]?
    }

    public func checkAvailability() async -> RefinementAvailability {
        do {
            let names = try await installedModels()
            if names.contains(where: { $0 == model || $0.hasPrefix(model + ":") }) {
                return .available
            }
            return .modelMissing(available: names)
        } catch {
            return .serverUnreachable(error.localizedDescription)
        }
    }

    /// Model names installed on the local Ollama server (`/api/tags`).
    public func installedModels() async throws -> [String] {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RefinementError.unavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return (decoded.models ?? []).map(\.name)
    }

    // MARK: - Refinement

    struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Options: Encodable {
            let temperature: Double
            let num_predict: Int
        }
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }

    /// Builds the `/api/chat` request body (exposed for unit tests).
    public static func requestBody(model: String, transcript: String, context: RefinementContext) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: RefinementPromptBuilder.systemPrompt(for: context)),
                .init(role: "user", content: RefinementPromptBuilder.userPrompt(transcript: transcript)),
            ],
            stream: false,
            // Cap generation relative to input so a runaway model cannot
            // produce unbounded output.
            options: .init(temperature: 0.2, num_predict: max(256, transcript.count)))
        return try JSONEncoder().encode(request)
    }

    public func refine(_ transcript: String, context: RefinementContext) async throws -> String {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(model: model, transcript: transcript, context: context)
        request.timeoutInterval = context.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw RefinementError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RefinementError.unavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RefinementError.invalidResponse("HTTP \(code)")
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.message?.content else {
            throw RefinementError.invalidResponse("unexpected /api/chat payload")
        }
        return content
    }
}
