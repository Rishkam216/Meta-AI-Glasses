import Foundation

protocol OpenAIRealtimeTransport: Sendable {
    func connect(_ request: URLRequest) async throws
    func send(text: String) async throws
    func receive() async throws -> String?
    func close() async
}

actor URLSessionOpenAIRealtimeTransport: OpenAIRealtimeTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: configuration)
    }

    func connect(_ request: URLRequest) throws {
        guard task == nil else {
            throw OpenAIRealtimeError.invalidState
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(text: String) async throws {
        guard let task else {
            throw OpenAIRealtimeError.invalidState
        }
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        guard let task else {
            throw OpenAIRealtimeError.invalidState
        }
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            guard data.count <= OpenAIRealtimeLimits.maxInboundBytes,
                  let text = String(data: data, encoding: .utf8) else {
                throw OpenAIRealtimeError.invalidResponse
            }
            return text
        @unknown default:
            throw OpenAIRealtimeError.invalidResponse
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }
}
