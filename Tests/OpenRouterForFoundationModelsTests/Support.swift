// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import OpenRouterAPI
import Synchronization
import Testing

@testable import OpenRouterForFoundationModels

// MARK: - SSE fixtures

/// Joins `data:` payloads into a wire body, appending the `[DONE]` sentinel.
func sseBody(_ payloads: [String], done: Bool = true) -> Data {
  var frames = payloads.map { "data: \($0)\n\n" }
  if done { frames.append("data: [DONE]\n\n") }
  return Data(frames.joined().utf8)
}

func jsonEscaped(_ text: String) -> String {
  String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
}

/// A complete assistant turn streaming `deltas` as text content.
func textTurnSSE(
  deltas: [String],
  promptTokens: Int = 10,
  cachedTokens: Int = 0,
  completionTokens: Int = 5,
  reasoningTokens: Int = 0
) -> Data {
  var payloads = [
    #"{"id":"gen-1","model":"test/model","choices":[{"delta":{"role":"assistant","content":""}}]}"#
  ]
  for delta in deltas {
    payloads.append(
      #"{"id":"gen-1","choices":[{"delta":{"content":\#(jsonEscaped(delta))}}]}"#
    )
  }
  payloads.append(
    #"{"id":"gen-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":\#(promptTokens),"completion_tokens":\#(completionTokens),"total_tokens":\#(promptTokens + completionTokens),"prompt_tokens_details":{"cached_tokens":\#(cachedTokens)},"completion_tokens_details":{"reasoning_tokens":\#(reasoningTokens)}}}"#
  )
  return sseBody(payloads)
}

/// A turn that streams reasoning (text and optionally `reasoning_details`)
/// before its text content.
func reasoningTurnSSE(
  reasoningDeltas: [String],
  detailChunks: [String] = [],
  text: String = "Hello!"
) -> Data {
  var payloads: [String] = []
  for delta in reasoningDeltas {
    payloads.append(
      #"{"id":"gen-1","choices":[{"delta":{"reasoning":\#(jsonEscaped(delta))}}]}"#
    )
  }
  for chunk in detailChunks {
    payloads.append(
      #"{"id":"gen-1","choices":[{"delta":{"reasoning_details":[\#(chunk)]}}]}"#
    )
  }
  payloads.append(#"{"id":"gen-1","choices":[{"delta":{"content":\#(jsonEscaped(text))}}]}"#)
  payloads.append(
    #"{"id":"gen-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":42}}"#
  )
  return sseBody(payloads)
}

/// A turn that streams one tool call with fragmented arguments.
func toolCallTurnSSE(id: String, name: String, argumentChunks: [String]) -> Data {
  var payloads = [
    #"{"id":"gen-1","choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":""}}]}}]}"#
  ]
  for chunk in argumentChunks {
    payloads.append(
      #"{"id":"gen-1","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":\#(jsonEscaped(chunk))}}]}}]}"#
    )
  }
  payloads.append(
    #"{"id":"gen-1","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":8}}"#
  )
  return sseBody(payloads)
}

// MARK: - Transport

/// Serves the configured responses in order, repeating the last one, and
/// records every request it saw.
final class MockTransport: HTTPTransport {
  private struct CannedResponse {
    let status: Int
    let body: Data
  }

  private let responses: [CannedResponse]
  private let recorded = Mutex<[URLRequest]>([])

  init(status: Int = 200, body: Data) {
    self.responses = [CannedResponse(status: status, body: body)]
  }

  init(responses: [(status: Int, body: Data)]) {
    precondition(!responses.isEmpty, "MockTransport needs at least one response")
    self.responses = responses.map { CannedResponse(status: $0.status, body: $0.body) }
  }

  var lastRequest: URLRequest? { recorded.withLock { $0.last } }
  var requests: [URLRequest] { recorded.withLock { $0 } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let canned = next(recording: request)
    return (canned.body, response(request, canned))
  }

  func bytes(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
    let canned = next(recording: request)
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in canned.body { continuation.yield(byte) }
      continuation.finish()
    }
    return (stream, response(request, canned))
  }

  private func next(recording request: URLRequest) -> CannedResponse {
    recorded.withLock {
      $0.append(request)
      return responses[min($0.count - 1, responses.count - 1)]
    }
  }

  private func response(_ request: URLRequest, _ canned: CannedResponse) -> URLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: canned.status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
  }
}

/// The JSON body of the transport's request at `index`, decoded for
/// assertions.
func requestBody(of transport: MockTransport, at index: Int = 0) throws -> [String: Any] {
  let request = try #require(transport.requests.count > index ? transport.requests[index] : nil)
  let body = try #require(request.httpBody)
  return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

// MARK: - Framework request construction

extension LanguageModelExecutorGenerationRequest {
  /// The SDK's memberwise initializer has no defaults; tests only vary a few
  /// fields.
  static func make(
    transcript: Transcript,
    enabledTools: [Transcript.ToolDefinition] = [],
    schema: GenerationSchema? = nil,
    generationOptions: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: [String: any Sendable & Codable & Equatable] = [:]
  ) -> Self {
    Self(
      id: UUID(),
      transcript: transcript,
      enabledTools: enabledTools,
      schema: schema,
      generationOptions: generationOptions,
      contextOptions: contextOptions,
      metadata: metadata
    )
  }
}

extension OpenRouterExecutor.Configuration {
  /// Cache markers default off so message-shape assertions stay simple;
  /// caching tests opt in.
  static func make(
    model: OpenRouterModel = "test/model",
    reasoning: ReasoningPolicy? = nil,
    provider: OpenRouterForFoundationModels.ProviderPreferences? = nil,
    serverTools: Set<OpenRouterServerTool> = [],
    fallbackModels: [String] = [],
    caching: CachePolicy = .disabled,
    transforms: [String] = []
  ) -> Self {
    .init(
      model: model,
      baseURL: URL(string: "https://stub.invalid")!,
      authMode: .apiKey("sk-test"),
      timeout: 5,
      reasoning: reasoning,
      provider: provider,
      serverTools: serverTools,
      fallbackModels: fallbackModels,
      caching: caching,
      transforms: transforms
    )
  }
}

// MARK: - Stubbed model

/// A `LanguageModel` whose executor is a real `OpenRouterExecutor` over an
/// injected transport, so `LanguageModelSession` exercises the full pipeline
/// offline — request building, SSE parsing, translation, and the framework's
/// transcript assembly.
struct StubbedOpenRouterModel: LanguageModel {
  typealias Executor = StubbedExecutor

  let transport: MockTransport
  let model: OpenRouterModel
  let attribution: Attribution?
  let caching: CachePolicy
  let structuredOutputRetries: Int

  init(
    transport: MockTransport,
    model: OpenRouterModel = "test/model",
    attribution: Attribution? = nil,
    caching: CachePolicy = .automatic,
    structuredOutputRetries: Int = 0
  ) {
    self.transport = transport
    self.model = model
    self.attribution = attribution
    self.caching = caching
    self.structuredOutputRetries = structuredOutputRetries
  }

  init(fixture: Data) {
    self.init(transport: MockTransport(body: fixture))
  }

  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities([.toolCalling, .reasoning, .guidedGeneration, .vision])
  }

  var executorConfiguration: StubbedExecutor.Configuration {
    .init(
      transport: transport,
      model: model,
      attribution: attribution,
      caching: caching,
      structuredOutputRetries: structuredOutputRetries
    )
  }
}

struct StubbedExecutor: LanguageModelExecutor {
  typealias Model = StubbedOpenRouterModel

  struct Configuration: Hashable, Sendable {
    let transport: MockTransport
    let model: OpenRouterModel
    let attribution: Attribution?
    let caching: CachePolicy
    let structuredOutputRetries: Int

    static func == (a: Self, b: Self) -> Bool {
      a.transport === b.transport && a.model == b.model
        && a.attribution == b.attribution && a.caching == b.caching
        && a.structuredOutputRetries == b.structuredOutputRetries
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(transport))
      hasher.combine(model)
    }
  }

  private let inner: OpenRouterExecutor
  private let model: OpenRouterModel

  init(configuration: Configuration) {
    self.model = configuration.model
    self.inner = OpenRouterExecutor(
      configuration: .init(
        model: configuration.model,
        baseURL: URL(string: "https://stub.invalid")!,
        authMode: .apiKey("sk-test"),
        timeout: 5,
        attribution: configuration.attribution,
        caching: configuration.caching,
        structuredOutputRetries: configuration.structuredOutputRetries
      ),
      transport: configuration.transport
    )
  }

  func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: StubbedOpenRouterModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    try await inner.respond(
      to: request,
      model: OpenRouterLanguageModel(name: self.model, auth: .apiKey("sk-test")),
      streamingInto: channel
    )
  }
}

// MARK: - Transcript helpers

/// Text of every reasoning entry in the transcript, in order, joined.
func reasoningText(in transcript: Transcript) -> String {
  transcript
    .compactMap { entry -> Transcript.Reasoning? in
      if case .reasoning(let r) = entry { return r }
      return nil
    }
    .flatMap(\.segments)
    .compactMap { segment -> String? in
      if case .text(let t) = segment { return t.content }
      return nil
    }
    .joined()
}

/// Reasoning entries in the transcript, in order.
func reasoningEntries(in transcript: Transcript) -> [Transcript.Reasoning] {
  transcript.compactMap { entry in
    if case .reasoning(let r) = entry { return r }
    return nil
  }
}
