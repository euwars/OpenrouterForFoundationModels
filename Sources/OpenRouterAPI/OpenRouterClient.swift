// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Thin HTTP client for `POST {baseURL}/v1/chat/completions`.
package struct OpenRouterClient: Sendable {
  package let configuration: Configuration
  private let transport: any HTTPTransport

  /// Production initializer — talks to OpenRouter over `URLSession`.
  package init(configuration: Configuration, session: URLSession = .shared) {
    self.init(configuration: configuration, transport: URLSessionTransport(session: session))
  }

  /// Inject a transport. Production passes ``URLSessionTransport``; tests pass
  /// a fake so the client can be exercised without a network.
  package init(configuration: Configuration, transport: any HTTPTransport) {
    self.configuration = configuration
    self.transport = transport
  }

  // MARK: - Non-streaming

  /// - Parameter headers: Additional headers for this request, merged over
  ///   the configuration's defaults. Use for attribution (`HTTP-Referer`,
  ///   `X-Title`) or proxy authorization.
  package func send(
    _ request: ChatRequest,
    headers: [String: String] = [:]
  ) async throws -> ChatResponse {
    var req = request
    req.stream = false
    let (data, response) = try await transport.data(for: urlRequest(for: req, headers: headers))
    try Self.check(response, body: data)
    return try JSONDecoder().decode(ChatResponse.self, from: data)
  }

  // MARK: - Streaming

  /// Streams the response as it generates. HTTP error statuses and mid-stream
  /// error chunks both surface by throwing ``APIError`` from the stream.
  package func stream(
    _ request: ChatRequest,
    headers: [String: String] = [:]
  ) -> AsyncThrowingStream<ChatChunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var req = request
          req.stream = true
          let (bytes, response) = try await transport.bytes(
            for: urlRequest(for: req, headers: headers)
          )
          if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // Error responses arrive as a JSON body, not SSE.
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            try Self.check(response, body: body)
          }
          for try await chunk in SSEParser.chunks(from: bytes) {
            continuation.yield(chunk)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Request building

  /// The chat-completions endpoint for `baseURL`. Accepts both base-URL
  /// conventions: a host root (`https://openrouter.ai/api`) gets
  /// `v1/chat/completions` appended, while a URL already ending in the
  /// OpenAI-style `/v1` (`https://openrouter.ai/api/v1` — what every
  /// OpenAI-compatible SDK uses) gets only `chat/completions`.
  package static func endpoint(for baseURL: URL) -> URL {
    let lastComponent = baseURL.pathComponents.last { $0 != "/" }
    return lastComponent == "v1"
      ? baseURL.appending(path: "chat/completions")
      : baseURL.appending(path: "v1/chat/completions")
  }

  private func urlRequest(
    for body: ChatRequest,
    headers: [String: String]
  ) throws -> URLRequest {
    var req = URLRequest(url: Self.endpoint(for: configuration.baseURL))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.setValue(Telemetry.userAgent, forHTTPHeaderField: "User-Agent")
    switch configuration.auth {
    case .bearer(let key):
      req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    case .none:
      break
    }
    for (key, value) in headers {
      req.setValue(value, forHTTPHeaderField: key)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    req.httpBody = try encoder.encode(body)
    return req
  }

  private static func check(_ response: URLResponse, body: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard http.statusCode >= 400 else { return }
    // Correlator for support and log lookup. OpenRouter exposes
    // X-Generation-Id on generations; error responses usually carry only
    // the CDN's cf-ray.
    let requestID =
      http.value(forHTTPHeaderField: "X-Generation-Id")
      ?? http.value(forHTTPHeaderField: "cf-ray")
    if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body) {
      var error = envelope.error
      // The envelope's code is authoritative, but intermediaries sometimes
      // omit it — fall back to the HTTP status.
      if error.code == 0 { error.code = http.statusCode }
      error.requestID = requestID
      throw error
    }
    // Cap the body excerpt so unexpected error pages can't flood logs via
    // errorDescription. Without an envelope the status is the only
    // classification signal — intermediaries (proxies, CDNs) answer auth and
    // rate-limit failures with non-JSON bodies.
    let maxBodyExcerpt = 512
    var excerpt = String(decoding: body.prefix(maxBodyExcerpt), as: UTF8.self)
    if body.count > maxBodyExcerpt {
      excerpt += "… [truncated, \(body.count) bytes total]"
    }
    throw APIError(
      code: http.statusCode,
      message: "HTTP \(http.statusCode): \(excerpt)",
      requestID: requestID
    )
  }
}
