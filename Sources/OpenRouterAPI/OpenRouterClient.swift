// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin HTTP client for OpenRouter's chat completions and Decisions endpoints.
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
    let (data, response) = try await transport.data(
      for: urlRequest(.chatCompletions, body: req, headers: headers)
    )
    try Self.check(response, body: data)
    return try JSONDecoder().decode(ChatResponse.self, from: data)
  }

  // MARK: - Decisions

  /// `POST {apiRoot}/alpha/decisions`. Plain JSON both ways, no SSE.
  ///
  /// - Parameter timeout: Set on the `URLRequest`, so a caller on a shared
  ///   session still gets its own bound. `nil` keeps the session's.
  package func decide(
    _ request: DecisionsRequest,
    headers: [String: String] = [:],
    timeout: TimeInterval? = nil
  ) async throws -> DecisionsResponse {
    var urlRequest = try urlRequest(.decisions, body: request, headers: headers)
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    if let timeout { urlRequest.timeoutInterval = timeout }
    let (data, response) = try await transport.data(for: urlRequest)
    try Self.check(response, body: data)
    return try JSONDecoder().decode(DecisionsResponse.self, from: data)
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
            for: urlRequest(.chatCompletions, body: req, headers: headers)
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

  package enum Endpoint: Sendable {
    /// `{apiRoot}/v1/chat/completions`
    case chatCompletions
    /// `{apiRoot}/alpha/decisions`. Decisions live beside `v1`, not in it.
    case decisions
  }

  /// The URL of `endpoint` for `baseURL`. Accepts both base-URL
  /// conventions by first reducing the base to the API root: a host root
  /// (`https://openrouter.ai/api`, or a proxy path) is the root as-is,
  /// while a base ending in the OpenAI-style `/v1`
  /// (`https://openrouter.ai/api/v1`, what OpenAI-compatible SDKs use) has
  /// that component dropped. Every endpoint then hangs off the one root.
  package static func endpoint(_ endpoint: Endpoint, for baseURL: URL) -> URL {
    let lastComponent = baseURL.pathComponents.last { $0 != "/" }
    let apiRoot = lastComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
    return switch endpoint {
    case .chatCompletions: apiRoot.appending(path: "v1/chat/completions")
    case .decisions: apiRoot.appending(path: "alpha/decisions")
    }
  }

  private func urlRequest(
    _ endpoint: Endpoint,
    body: some Encodable,
    headers: [String: String]
  ) throws -> URLRequest {
    var req = URLRequest(url: Self.endpoint(endpoint, for: configuration.baseURL))
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
