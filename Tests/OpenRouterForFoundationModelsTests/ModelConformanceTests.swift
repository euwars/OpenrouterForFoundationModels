// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import Testing

@testable import OpenRouterForFoundationModels

private let conformanceKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""

/// Per-model conformance harness against the live API. Add a model ID to
/// ``ModelConformanceTests/models`` and every check runs for it:
///
///     OPENROUTER_API_KEY=<key> swift test --filter ModelConformanceTests
///
/// Failures are information, not breakage — a model that flunks a check
/// doesn't support that behavior (or its OpenRouter endpoints don't), and
/// that's exactly what `VendorDefaults` should record.
@Suite(.enabled(if: !conformanceKey.isEmpty), .serialized)
struct ModelConformanceTests {
  /// One line per model under test — the most-used model of each of the top
  /// 15 vendors on OpenRouter. Results seed `VendorDefaults`.
  static let models: [String] = [
    "openai/gpt-5.6-luna",
    "anthropic/claude-opus-5",
    "google/gemini-3.6-flash",
    "deepseek/deepseek-v4-flash",
    "qwen/qwen3.7-max",
    "x-ai/grok-4.5",
    "moonshotai/kimi-k3",
    "meta-llama/llama-4-maverick",
    "z-ai/glm-5.2",
    "mistralai/mistral-medium-3-5",
    "minimax/minimax-m3",
    "nvidia/nemotron-3-ultra-550b-a55b",
    "amazon/nova-2-lite-v1",
    "cohere/command-a",
    "bytedance-seed/seed-2.0-lite",
  ]

  @Test(.timeLimit(.minutes(4)), arguments: models)
  func `strict structured output with guide enforcement`(modelID: String) async throws {
    let session = LanguageModelSession(
      model: OpenRouterLanguageModel(name: .init(id: modelID), auth: .apiKey(conformanceKey))
    )
    let response = try await session.respond(
      to: "Pack for 3 days somewhere hot.",
      generating: PackingList.self
    )
    // Decoding proves strict structured output; the counts prove the
    // provider enforced @Guide bounds rather than treating them as hints.
    #expect(
      response.content.items.count == 3,
      "\(modelID): expected .count(3) enforced, got \(response.content.items.count) items"
    )
    #expect((1...7).contains(response.content.days), "\(modelID): .range(1...7) violated")
  }

  @Test(.timeLimit(.minutes(4)), arguments: models)
  func `reasoning spends thinking tokens`(modelID: String) async throws {
    let session = LanguageModelSession(
      model: OpenRouterLanguageModel(
        name: .init(id: modelID),
        auth: .apiKey(conformanceKey),
        reasoning: .effort(.high)
      )
    )
    _ = try await session.respond(
      to: "A farmer has 17 sheep. All but 9 run away, then he buys twice as many as remain. How many now? Answer with just the number."
    )
    #expect(
      session.usage.output.reasoningTokenCount > 0,
      "\(modelID): no reasoning tokens reported"
    )
  }

  @Test(.timeLimit(.minutes(4)), arguments: models)
  func `tool calling round-trips`(modelID: String) async throws {
    let session = LanguageModelSession(
      model: OpenRouterLanguageModel(name: .init(id: modelID), auth: .apiKey(conformanceKey)),
      tools: [LookupTool()],
      instructions: "Always answer using the lookup tool."
    )
    _ = try await session.respond(to: "What is the capital of Portugal?")
    let calls = session.transcript.compactMap { entry -> Transcript.ToolCalls? in
      if case .toolCalls(let c) = entry { return c }
      return nil
    }
    #expect(!calls.isEmpty, "\(modelID): never called the tool")
  }
}

@Generable(description: "A packing list")
fileprivate struct PackingList {
  @Guide(description: "Trip climate")
  var climate: Climate
  @Guide(description: "Exactly three items to pack", .count(3))
  var items: [String]
  @Guide(description: "Days the list covers", .range(1...7))
  var days: Int
}

@Generable(description: "A climate")
fileprivate enum Climate {
  case cold, temperate, hot
}

private struct LookupTool: Tool {
  let name = "lookup"
  let description = "Look up a fact"

  @Generable
  struct Arguments {
    @Guide(description: "The question to look up")
    var query: String
  }

  func call(arguments: Arguments) async throws -> String {
    "Lisbon"
  }
}
