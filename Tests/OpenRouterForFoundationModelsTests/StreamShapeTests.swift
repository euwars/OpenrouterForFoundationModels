// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import Testing

@testable import OpenRouterForFoundationModels

/// Hostile and edge-case wire shapes, run through the full session pipeline.
@Suite struct StreamShapeTests {
  @Test func `delta token counts are nonzero so partial snapshots deliver`() {
    // The framework paces snapshot delivery by reported token counts; a zero
    // count defers everything to one final snapshot.
    #expect(EventTranslator.deltaTokenCount > 0)
  }

  @Test func `interleaved reasoning, text, and tool calls keep their lanes`() async throws {
    let firstTurn = [
      #"{"id":"g","choices":[{"delta":{"reasoning":"think 1 "}}]}"#,
      #"{"id":"g","choices":[{"delta":{"content":"Checking. "}}]}"#,
      #"{"id":"g","choices":[{"delta":{"reasoning":"think 2"}}]}"#,
      #"{"id":"g","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}}]}}]}"#,
      #"{"id":"g","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":9}}"#,
    ]
    let transport = MockTransport(
      responses: [
        (200, sseBody(firstTurn)),
        (200, textTurnSSE(deltas: ["72F."])),
      ]
    )
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(transport: transport),
      tools: [InterleaveWeatherTool()]
    )
    let response = try await session.respond(to: "Weather?")
    #expect(response.content == "72F.")
    #expect(reasoningText(in: session.transcript) == "think 1 think 2")

    let toolCallEntries = session.transcript.compactMap { entry -> Transcript.ToolCalls? in
      if case .toolCalls(let calls) = entry { return calls }
      return nil
    }
    #expect(toolCallEntries.count == 1)
  }

  @Test func `structured output survives single-character chunks`() async throws {
    let json = #"{"city":"Kyoto"}"#
    let transport = MockTransport(
      body: textTurnSSE(deltas: json.map(String.init))
    )
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    let response = try await session.respond(to: "Where?", generating: ChunkedCity.self)
    #expect(response.content.city == "Kyoto")
  }

  @Test func `tool call arguments split across many tiny deltas round-trip`() async throws {
    let argumentChunks = #"{"city":"SF"}"#.map(String.init)
    let transport = MockTransport(
      responses: [
        (200, toolCallTurnSSE(id: "call_1", name: "get_weather", argumentChunks: argumentChunks)),
        (200, textTurnSSE(deltas: ["Done."])),
      ]
    )
    let session = LanguageModelSession(
      model: StubbedOpenRouterModel(transport: transport),
      tools: [InterleaveWeatherTool()]
    )
    let response = try await session.respond(to: "Weather?")
    #expect(response.content == "Done.")
  }

  @Test func `empty first delta with role does not create phantom content`() async throws {
    let payloads = [
      #"{"id":"g","choices":[{"delta":{"role":"assistant","content":""}}]}"#,
      #"{"id":"g","choices":[{"delta":{"content":"Real text."}}]}"#,
      #"{"id":"g","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":2}}"#,
    ]
    let transport = MockTransport(body: sseBody(payloads))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    let response = try await session.respond(to: "hi")
    #expect(response.content == "Real text.")
  }

  @Test func `cancelling a stream stops cleanly`() async throws {
    let transport = MockTransport(body: textTurnSSE(deltas: Array(repeating: "chunk ", count: 50)))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    let task = Task {
      var latest = ""
      for try await snapshot in session.streamResponse(to: "hi") {
        latest = snapshot.content
      }
      return latest
    }
    task.cancel()
    // Cancellation may surface as CancellationError or a truncated success —
    // either is acceptable; what matters is that it neither hangs nor crashes.
    _ = try? await task.value
  }

  @Test func `chunks with no choices are tolerated`() async throws {
    let payloads = [
      #"{"id":"g","object":"chat.completion.chunk"}"#,
      #"{"id":"g","choices":[{"delta":{"content":"ok"}}]}"#,
      #"{"id":"g","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#,
    ]
    let transport = MockTransport(body: sseBody(payloads))
    let session = LanguageModelSession(model: StubbedOpenRouterModel(transport: transport))
    let response = try await session.respond(to: "hi")
    #expect(response.content == "ok")
  }
}

private struct InterleaveWeatherTool: Tool {
  let name = "get_weather"
  let description = "Get the weather"

  @Generable
  struct Arguments {
    var city: String
  }

  func call(arguments: Arguments) async throws -> String {
    "Sunny in \(arguments.city)"
  }
}

@Generable
private struct ChunkedCity {
  var city: String
}
