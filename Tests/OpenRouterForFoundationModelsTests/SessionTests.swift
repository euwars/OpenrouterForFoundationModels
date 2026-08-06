// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import OpenRouterAPI
import Testing

@testable import OpenRouterForFoundationModels

/// Full-pipeline tests: a real `LanguageModelSession` drives a real
/// `OpenRouterExecutor` over an injected transport — request building, SSE
/// parsing, translation, and the framework's transcript assembly all run.
@Suite struct SessionTests {
  @Test func `text turn streams content and reports usage`() async throws {
    let transport = MockTransport(
      body: textTurnSSE(
        deltas: ["Hel", "lo!"],
        promptTokens: 12,
        cachedTokens: 4,
        completionTokens: 7,
        reasoningTokens: 2
      )
    )
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))

    var latest = ""
    for try await snapshot in session.streamResponse(to: "hi") {
      latest = snapshot.content
    }
    #expect(latest == "Hello!")

    let usage = session.usage
    #expect(usage.input.totalTokenCount == 12)
    #expect(usage.input.cachedTokenCount == 4)
    #expect(usage.output.totalTokenCount == 7)
  }

  @Test func `request carries auth, attribution, and endpoint path`() async throws {
    let transport = MockTransport(body: textTurnSSE(deltas: ["ok"]))
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(
        transport: transport,
        attribution: Attribution(
          siteURL: URL(string: "https://example.app")!,
          appName: "TestApp"
        )
      )
    )
    _ = try await session.respond(to: "hi")

    let request = try #require(transport.lastRequest)
    #expect(request.url?.path().hasSuffix("v1/chat/completions") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(request.value(forHTTPHeaderField: "X-Title") == "TestApp")
    #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.app")
    let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
    #expect(agent.hasPrefix("OpenRouterForFoundationModels/"))
  }

  @Test func `reasoning deltas surface as reasoning entries`() async throws {
    let transport = MockTransport(
      body: reasoningTurnSSE(reasoningDeltas: ["Let me think. ", "Okay."])
    )
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))

    var latest = ""
    for try await snapshot in session.streamResponse(to: "hi") {
      latest = snapshot.content
    }
    #expect(latest == "Hello!")
    #expect(reasoningText(in: session.transcript) == "Let me think. Okay.")
  }

  @Test func `reasoning_details accumulate onto the reasoning entry and replay next turn`()
    async throws
  {
    let details = [
      #"{"type":"reasoning.text","index":0,"text":"I sho"}"#,
      #"{"type":"reasoning.text","index":0,"text":"uld check.","signature":"sig123"}"#,
    ]
    let transport = MockTransport(
      responses: [
        (200, reasoningTurnSSE(reasoningDeltas: ["thinking"], detailChunks: details)),
        (200, textTurnSSE(deltas: ["Sure."])),
      ]
    )
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))

    _ = try await session.respond(to: "hi")

    // The entry carries the merged details as JSON signature bytes.
    let entry = try #require(reasoningEntries(in: session.transcript).first)
    let payload = try #require(entry.signature)
    let value = try JSONDecoder().decode(JSONValue.self, from: payload)
    #expect(
      value
        == .array([
          .object([
            "type": .string("reasoning.text"),
            "index": .number(0),
            "text": .string("I should check."),
            "signature": .string("sig123"),
          ])
        ])
    )

    // Next turn replays them verbatim on the prior assistant message.
    _ = try await session.respond(to: "again")
    let body = try requestBody(of: transport, at: 1)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let assistant = try #require(
      messages.first { $0["role"] as? String == "assistant" }
    )
    #expect(assistant["reasoning"] as? String == "thinking")
    let replayed = try #require(assistant["reasoning_details"] as? [[String: Any]])
    #expect(replayed.count == 1)
    #expect(replayed[0]["text"] as? String == "I should check.")
    #expect(replayed[0]["signature"] as? String == "sig123")
  }

  @Test func `reasoning_content deltas surface as reasoning entries too`() async throws {
    // DeepSeek-style upstreams spell the field reasoning_content.
    let payloads = [
      #"{"id":"gen-1","choices":[{"delta":{"reasoning_content":"Let me think."}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{"content":"Hello!"}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
    ]
    let transport = MockTransport(body: sseBody(payloads))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    let response = try await session.respond(to: "hi")
    #expect(response.content == "Hello!")
    #expect(reasoningText(in: session.transcript) == "Let me think.")
  }

  @Test func `content_filter finish reason fails the turn as a guardrail violation`()
    async throws
  {
    let payloads = [
      #"{"id":"gen-1","choices":[{"delta":{"content":"par"}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{},"finish_reason":"content_filter"}]}"#,
    ]
    let transport = MockTransport(body: sseBody(payloads))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    await #expect(throws: LanguageModelError.self) {
      _ = try await session.respond(to: "hi")
    }
  }

  @Test func `streamed refusal fails the turn instead of finishing empty`() async throws {
    let payloads = [
      #"{"id":"gen-1","choices":[{"delta":{"refusal":"I can't "}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{"refusal":"help with that."}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
    ]
    let transport = MockTransport(body: sseBody(payloads))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    await #expect(throws: LanguageModelError.self) {
      _ = try await session.respond(to: "hi")
    }
  }

  @Test func `web search annotations surface as citation segments`() async throws {
    let payloads = [
      #"{"id":"gen-1","choices":[{"delta":{"content":"Big news. "}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"Example A","content":"excerpt","start_index":0,"end_index":8}}]}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{"content":"More."}}]}"#,
      #"{"id":"gen-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
    ]
    let transport = MockTransport(body: sseBody(payloads))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    let response = try await session.respond(to: "News?")
    #expect(response.content.contains("Big news."))

    let citations = session.transcript
      .flatMap { entry -> [Transcript.Segment] in
        if case .response(let r) = entry { return r.segments }
        return []
      }
      .compactMap { segment -> OpenRouterCitationSegment? in
        if case .custom(let custom) = segment { return custom as? OpenRouterCitationSegment }
        return nil
      }
    #expect(citations.count == 1)
    #expect(citations.first?.content.url == "https://example.com/a")
    #expect(citations.first?.content.title == "Example A")
    #expect(citations.first?.content.excerpt == "excerpt")
  }

  @Test func `metadata user key flows to the wire`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        metadata: [OpenRouterMetadata.user: "user-1234"]
      ),
      configuration: .make()
    )
    #expect(request.user == "user-1234")
  }

  @Test func `tool calls execute and the follow-up request replays them`() async throws {
    let transport = MockTransport(
      responses: [
        (
          200,
          toolCallTurnSSE(
            id: "call_1",
            name: "get_weather",
            argumentChunks: [#"{"city"#, #"":"SF"}"#]
          )
        ),
        (200, textTurnSSE(deltas: ["72F and sunny."])),
      ]
    )
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(transport: transport),
      tools: [WeatherTool()]
    )
    let response = try await session.respond(to: "Weather in SF?")
    #expect(response.content == "72F and sunny.")

    // The follow-up request must replay the assistant tool call and the
    // tool-role result keyed by the originating call ID.
    let body = try requestBody(of: transport, at: 1)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let assistant = try #require(
      messages.first { $0["role"] as? String == "assistant" }
    )
    let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
    #expect(calls.count == 1)
    #expect(calls[0]["id"] as? String == "call_1")
    let function = try #require(calls[0]["function"] as? [String: Any])
    #expect(function["name"] as? String == "get_weather")
    let toolMessage = try #require(
      messages.first { $0["role"] as? String == "tool" }
    )
    #expect(toolMessage["tool_call_id"] as? String == "call_1")
    #expect((toolMessage["content"] as? String)?.contains("Sunny") == true)
  }

  @Test func `guided generation sends strict response_format and decodes the result`()
    async throws
  {
    let transport = MockTransport(
      body: textTurnSSE(deltas: [#"{"city":"#, #""Kyoto"}"#])
    )
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))

    let response = try await session.respond(to: "Where?", generating: City.self)
    #expect(response.content.city == "Kyoto")

    let body = try requestBody(of: transport)
    let format = try #require(body["response_format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    let wrapper = try #require(format["json_schema"] as? [String: Any])
    #expect(wrapper["strict"] as? Bool == true)
    let schema = try #require(wrapper["schema"] as? [String: Any])
    #expect(schema["additionalProperties"] as? Bool == false)
    // Structured output auto-enables require_parameters routing.
    let provider = try #require(body["provider"] as? [String: Any])
    #expect(provider["require_parameters"] as? Bool == true)
  }

  @Test func `automatic caching marks the wire request`() async throws {
    let transport = MockTransport(body: textTurnSSE(deltas: ["ok"]))
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(transport: transport),
      instructions: "Be concise."
    )
    _ = try await session.respond(to: "hi")

    let body = try requestBody(of: transport)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let system = try #require(messages.first { $0["role"] as? String == "system" })
    let parts = try #require(system["content"] as? [[String: Any]])
    let control = try #require(parts[0]["cache_control"] as? [String: Any])
    #expect(control["type"] as? String == "ephemeral")
  }

  @Test func `schema rejection retries with minimal fidelity and remembers the model`()
    async throws
  {
    let rejection = Data(
      #"{"error":{"code":400,"message":"Provider returned error","metadata":{"provider_error_code":"invalid_json_schema"}}}"#
      .utf8
    )
    let transport = MockTransport(
      responses: [
        (400, rejection),
        (200, textTurnSSE(deltas: [#"{"days":3}"#])),
      ]
    )
    // A unique ID: the fidelity memo is process-wide, and this test
    // deliberately poisons its model.
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(transport: transport, model: "test/rejects-constraints")
    )

    let first = try await session.respond(to: "How long?", generating: Bounded.self)
    #expect(first.content.days == 3)

    // Attempt one carried the guide bounds; the retry stripped them.
    let fullBody = try requestBody(of: transport, at: 0)
    #expect(schemaJSON(of: fullBody).contains("minimum"))
    let minimalBody = try requestBody(of: transport, at: 1)
    #expect(!schemaJSON(of: minimalBody).contains("minimum"))

    // The model is remembered: the next request goes minimal directly.
    _ = try await session.respond(to: "Again?", generating: Bounded.self)
    #expect(transport.requests.count == 3)
    let rememberedBody = try requestBody(of: transport, at: 2)
    #expect(!schemaJSON(of: rememberedBody).contains("minimum"))
  }

  @Test func `stripped mode never sends constraints or probes`() async throws {
    let transport = MockTransport(body: textTurnSSE(deltas: [#"{"days":3}"#]))
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(
        transport: transport,
        model: OpenRouterModel(
          id: "test/stripped-model",
          capabilities: .init(guideConstraints: .stripped)
        )
      )
    )
    _ = try await session.respond(to: "How long?", generating: Bounded.self)
    #expect(transport.requests.count == 1)
    let body = try requestBody(of: transport)
    #expect(!schemaJSON(of: body).contains("minimum"))
  }

  @Test func `included mode surfaces schema rejections without retrying`() async throws {
    let rejection = Data(
      #"{"error":{"code":400,"message":"Provider returned error"}}"#.utf8
    )
    let transport = MockTransport(status: 400, body: rejection)
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(
        transport: transport,
        model: OpenRouterModel(
          id: "test/included-model",
          capabilities: .init(guideConstraints: .included)
        )
      )
    )
    await #expect(throws: OpenRouterError.self) {
      _ = try await session.respond(to: "How long?", generating: Bounded.self)
    }
    #expect(transport.requests.count == 1)
    let body = try requestBody(of: transport)
    #expect(schemaJSON(of: body).contains("minimum"))
  }

  @Test func `non-schema 400s do not retry`() async throws {
    let rejection = Data(#"{"error":{"code":400,"message":"Bad request"}}"#.utf8)
    let transport = MockTransport(status: 400, body: rejection)
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    await #expect(throws: OpenRouterError.self) {
      // No schema in the request — a 400 must surface immediately.
      _ = try await session.respond(to: "hi")
    }
    #expect(transport.requests.count == 1)
  }

  @Test func `HTTP 402 maps to insufficientCredits`() async throws {
    let transport = MockTransport(
      status: 402,
      body: Data(#"{"error":{"code":402,"message":"Insufficient credits"}}"#.utf8)
    )
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    await #expect(throws: OpenRouterError.self) {
      _ = try await session.respond(to: "hi")
    }
  }

  @Test func `HTTP 429 maps to the framework's rateLimited error`() async throws {
    let transport = MockTransport(
      status: 429,
      body: Data(#"{"error":{"code":429,"message":"Rate limited"}}"#.utf8)
    )
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    await #expect(throws: LanguageModelError.self) {
      _ = try await session.respond(to: "hi")
    }
  }

  @Test func `mid-stream error chunk fails the turn`() async throws {
    let payloads = [
      #"{"id":"gen-1","choices":[{"delta":{"content":"partial"}}]}"#,
      #"{"id":"gen-1","error":{"code":502,"message":"Provider disconnected"},"choices":[{"delta":{},"finish_reason":"error"}]}"#,
    ]
    let transport = MockTransport(body: sseBody(payloads))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    await #expect(throws: OpenRouterError.self) {
      var latest = ""
      for try await snapshot in session.streamResponse(to: "hi") {
        latest = snapshot.content
      }
      _ = latest
    }
  }
}

private struct WeatherTool: Tool {
  let name = "get_weather"
  let description = "Get the weather for a city"

  @Generable
  struct Arguments {
    var city: String
  }

  func call(arguments: Arguments) async throws -> String {
    "Sunny in \(arguments.city)"
  }
}

@Generable
private struct City {
  var city: String
}

@Generable
private struct Bounded {
  @Guide(description: "days", .range(1...5))
  var days: Int
}

/// The response-format schema of a captured request body, as compact JSON.
private func schemaJSON(of body: [String: Any]) -> String {
  guard
    let format = body["response_format"] as? [String: Any],
    let wrapper = format["json_schema"] as? [String: Any],
    let schema = wrapper["schema"],
    let data = try? JSONSerialization.data(withJSONObject: schema)
  else { return "" }
  return String(decoding: data, as: UTF8.self)
}
