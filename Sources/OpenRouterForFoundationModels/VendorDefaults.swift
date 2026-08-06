// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Measured per-vendor capability defaults — the single file that records
/// what each model family actually supports on OpenRouter.
///
/// Behavior is largely uniform within a vendor (`anthropic/*` models share
/// an API surface), so defaults are keyed by the vendor prefix of the model
/// ID. They apply only when a model is constructed from a bare ID; explicit
/// ``OpenRouterModel/Capabilities`` always win. Unlisted vendors get the
/// permissive defaults plus the automatic guide-constraint probe.
///
/// Sourced from `ModelConformanceTests` (run 2026-08-06 against each of the
/// top 15 vendors' most-used model). To re-derive or extend:
///
///     OPENROUTER_API_KEY=<key> swift test --filter ModelConformanceTests
enum VendorDefaults {
  /// Vendor slug (the part before `/` in a model ID) → measured defaults.
  static let table: [String: OpenRouterModel.Capabilities] = [
    // Verified: strict structured output with enforced @Guide bounds,
    // reasoning, and tool calling. `.included` skips the constraint probe.
    "openai": verified,
    "google": verified,
    "deepseek": verified,
    "qwen": verified,
    "x-ai": verified,
    "moonshotai": verified,
    "z-ai": verified,
    "mistralai": verified,
    "minimax": verified,
    "bytedance-seed": verified,

    // Anthropic's strict schema validator rejects @Guide bound keywords
    // (minItems, minimum, …) — the same reason Anthropic's own Foundation
    // Models package strips them. Structured output, reasoning, and tools
    // are otherwise fully verified.
    "anthropic": .init(guideConstraints: .stripped),

    // llama-4-maverick: structured output and tools verified; not a
    // reasoning model family.
    "meta-llama": .init(reasoning: false, guideConstraints: .included),

    // nova-2-lite: no OpenRouter endpoint accepts response_format
    // json_schema — guided generation 404s under require_parameters.
    "amazon": .init(structuredOutput: false),

    // command-a: no reasoning support; no tool-capable OpenRouter endpoint.
    "cohere": .init(toolCalling: false, reasoning: false),

    // nemotron-3-ultra: accepts json_schema but enforcement is unreliable
    // (returned output missing a required property), and its provider
    // disables thinking whenever response_format is set. Kept permissive
    // with the probe; expect guided generation to be best-effort.
    "nvidia": .init(),
  ]

  private static let verified = OpenRouterModel.Capabilities(guideConstraints: .included)

  /// Defaults for a model ID, by its vendor prefix.
  static func capabilities(for id: String) -> OpenRouterModel.Capabilities {
    let vendor = id.split(separator: "/").first.map(String.init) ?? id
    return table[vendor] ?? .init()
  }
}
