// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import OpenRouterForFoundationModels

private let liveKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""

/// Network tests against the real OpenRouter API. Skipped unless
/// `OPENROUTER_API_KEY` is set:
///
///     OPENROUTER_API_KEY=<key> swift test --filter LiveTests
@Suite(.enabled(if: !liveKey.isEmpty), .serialized)
struct LiveTests {
  @Test(.timeLimit(.minutes(4)))
  func `tool calling with reasoning replays thought blocks across turns`() async throws {
    // The strictest wire test: with reasoning on, the follow-up request
    // after a tool call must replay the reasoning_details blocks verbatim —
    // Anthropic validates the replayed thought chain and rejects a
    // reshaped payload.
    let model = OpenRouterLanguageModel(
      name: "anthropic/claude-sonnet-4.5",
      auth: .apiKey(liveKey),
      reasoning: .budget(1100)
    )
    let session = LanguageModelSession(
      model: model,
      tools: [WeatherTool()],
      instructions: "Answer using the get_weather tool."
    )
    let response = try await session.respond(to: "What's the weather in Lisbon right now?")

    let toolCallEntries = session.transcript.compactMap { entry -> Transcript.ToolCalls? in
      if case .toolCalls(let calls) = entry { return calls }
      return nil
    }
    #expect(!toolCallEntries.isEmpty, "expected the model to call get_weather")
    #expect(response.content.lowercased().contains("sunny") || !response.content.isEmpty)
  }

  @Test(.timeLimit(.minutes(4)))
  func `anthropic prompt caching reports cache hits on the second turn`() async throws {
    // Cache breakpoints only matter above the provider's minimum cacheable
    // prefix (~1024 tokens on Sonnet), so pad the instructions well past it.
    let ballast = String(
      repeating: "Style guide rule: prefer plain, literal wording over idioms. ",
      count: 220
    )
    let model = OpenRouterLanguageModel(
      name: "anthropic/claude-sonnet-4.5",
      auth: .apiKey(liveKey)
    )
    let session = LanguageModelSession(model: model, instructions: ballast)

    _ = try await session.respond(to: "Reply with the single word: one")
    _ = try await session.respond(to: "Reply with the single word: two")

    // usage is cumulative; a cache read on turn two shows up in the total.
    #expect(
      session.usage.input.cachedTokenCount > 1000,
      "expected the second turn to read the padded prefix from cache; got \(session.usage.input.cachedTokenCount)"
    )
  }

  @Test(.timeLimit(.minutes(4)))
  func `reasoning text streams from an effort-based model`() async throws {
    let model = OpenRouterLanguageModel(
      name: "openai/gpt-5.6-luna",
      auth: .apiKey(liveKey),
      reasoning: .effort(.high)
    )
    let session = LanguageModelSession(model: model)
    _ = try await session.respond(
      to: "A farmer has 17 sheep. All but 9 run away, then he buys twice as many as remain. How many sheep now? Answer with just the number."
    )
    // The model must at least have spent reasoning tokens; summarized
    // reasoning text additionally surfaces as transcript entries when the
    // provider chooses to emit a summary.
    #expect(session.usage.output.reasoningTokenCount > 0)
  }
}

private struct WeatherTool: Tool {
  let name = "get_weather"
  let description = "Get the current weather for a city"

  @Generable
  struct Arguments {
    @Guide(description: "City name")
    var city: String
  }

  func call(arguments: Arguments) async throws -> String {
    "Sunny, 22°C in \(arguments.city)"
  }
}
