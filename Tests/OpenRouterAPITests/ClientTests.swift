// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import OpenRouterAPI

/// Serves one canned response and records the request.
private final class StubTransport: HTTPTransport {
  let status: Int
  let body: Data
  let headers: [String: String]?
  private let recorded = Mutex<URLRequest?>(nil)

  init(status: Int = 200, body: Data, headers: [String: String]? = nil) {
    self.status = status
    self.body = body
    self.headers = headers
  }

  var lastRequest: URLRequest? { recorded.withLock { $0 } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.withLock { $0 = request }
    return (body, response(request))
  }

  func bytes(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
    recorded.withLock { $0 = request }
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in body { continuation.yield(byte) }
      continuation.finish()
    }
    return (stream, response(request))
  }

  private func response(_ request: URLRequest) -> URLResponse {
    HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
    )!
  }
}

private func drain(_ stream: AsyncThrowingStream<ChatChunk, Error>) async throws -> [ChatChunk] {
  var chunks: [ChatChunk] = []
  for try await chunk in stream { chunks.append(chunk) }
  return chunks
}

private let okBody = Data(
  """
  data: {"id":"gen-1","choices":[{"delta":{"content":"hi"}}]}

  data: [DONE]

  """.utf8
)

@Suite struct ClientTests {
  private func makeClient(_ transport: StubTransport, auth: Configuration.Auth = .bearer("sk-x"))
    -> OpenRouterClient
  {
    OpenRouterClient(configuration: .init(auth: auth), transport: transport)
  }

  @Test func `requests hit v1 chat completions with default headers`() async throws {
    let transport = StubTransport(body: okBody)
    _ = try await drain(
      makeClient(transport).stream(ChatRequest(model: "m", messages: []))
    )
    let request = try #require(transport.lastRequest)
    #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
    #expect(agent.hasPrefix("OpenRouterForFoundationModels/\(Telemetry.sdkVersion)"))
  }

  @Test func `base URLs with and without a v1 suffix reach the same endpoint`() async throws {
    // Both conventions are common: host roots, and the OpenAI-SDK-style
    // base URL that already ends in /v1.
    let cases: [(base: String, expected: String)] = [
      ("https://openrouter.ai/api", "https://openrouter.ai/api/v1/chat/completions"),
      ("https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/chat/completions"),
      ("https://openrouter.ai/api/v1/", "https://openrouter.ai/api/v1/chat/completions"),
      ("https://proxy.example.com", "https://proxy.example.com/v1/chat/completions"),
      ("https://proxy.example.com/openrouter", "https://proxy.example.com/openrouter/v1/chat/completions"),
    ]
    for (base, expected) in cases {
      let endpoint = OpenRouterClient.endpoint(for: URL(string: base)!)
      #expect(endpoint.absoluteString == expected, "base: \(base)")
    }
  }

  @Test func `per-request headers merge over defaults`() async throws {
    let transport = StubTransport(body: okBody)
    _ = try await drain(
      makeClient(transport).stream(
        ChatRequest(model: "m", messages: []),
        headers: ["X-Title": "MyApp", "User-Agent": "custom-agent"]
      )
    )
    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "X-Title") == "MyApp")
    // Caller-supplied values win on conflict.
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "custom-agent")
  }

  @Test func `stream forces the stream flag on`() async throws {
    let transport = StubTransport(body: okBody)
    var body = ChatRequest(model: "m", messages: [])
    body.stream = false
    _ = try await drain(makeClient(transport).stream(body))
    let sent = try #require(transport.lastRequest?.httpBody)
    #expect(String(decoding: sent, as: UTF8.self).contains(#""stream":true"#))
  }

  @Test func `error envelopes on HTTP failures decode into APIError`() async throws {
    let transport = StubTransport(
      status: 402,
      body: Data(#"{"error":{"code":402,"message":"Add credits"}}"#.utf8)
    )
    await #expect {
      _ = try await drain(makeClient(transport).stream(ChatRequest(model: "m", messages: [])))
    } throws: { error in
      (error as? APIError)?.code == 402
    }
  }

  @Test func `errors carry the response's request correlator`() async throws {
    let transport = StubTransport(
      status: 429,
      body: Data(#"{"error":{"code":429,"message":"Slow down"}}"#.utf8),
      headers: ["cf-ray": "abc123-MRS"]
    )
    await #expect {
      _ = try await drain(makeClient(transport).stream(ChatRequest(model: "m", messages: [])))
    } throws: { error in
      guard let api = error as? APIError else { return false }
      return api.requestID == "abc123-MRS"
        && api.errorDescription?.contains("request_id: abc123-MRS") == true
    }
  }

  @Test func `non-JSON error bodies fall back to the HTTP status`() async throws {
    let transport = StubTransport(
      status: 503,
      body: Data("<html>Service Unavailable</html>".utf8)
    )
    await #expect {
      _ = try await drain(makeClient(transport).stream(ChatRequest(model: "m", messages: [])))
    } throws: { error in
      guard let api = error as? APIError else { return false }
      return api.code == 503 && api.message.contains("Service Unavailable")
    }
  }

  @Test func `oversized error bodies are truncated in the message`() async throws {
    let transport = StubTransport(
      status: 500,
      body: Data(String(repeating: "x", count: 5000).utf8)
    )
    await #expect {
      _ = try await drain(makeClient(transport).stream(ChatRequest(model: "m", messages: [])))
    } throws: { error in
      guard let api = error as? APIError else { return false }
      return api.message.count < 1000 && api.message.contains("truncated")
    }
  }

  @Test func `send decodes a non-streaming response`() async throws {
    let transport = StubTransport(
      body: Data(
        #"{"id":"gen-1","choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#
        .utf8
      )
    )
    let response = try await makeClient(transport).send(ChatRequest(model: "m", messages: []))
    #expect(response.choices.first?.message?.content == "hi")
    // send() must not request a stream.
    let sent = try #require(transport.lastRequest?.httpBody)
    #expect(String(decoding: sent, as: UTF8.self).contains(#""stream":false"#))
  }
}
