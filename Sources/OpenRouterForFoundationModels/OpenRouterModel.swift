// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An OpenRouter model ID and what it accepts.
///
/// OpenRouter serves hundreds of models behind one API and, unlike a direct
/// provider API, tolerates parameters an endpoint doesn't support (they are
/// dropped during routing unless `require_parameters` is set). Capabilities
/// therefore default to permissive — any ID works via a string literal:
///
/// ```swift
/// OpenRouterLanguageModel(name: "anthropic/claude-sonnet-4.5", auth: .apiKey(key))
/// ```
///
/// Turn a capability off when the framework should not route that kind of
/// work to the model at all — e.g. `structuredOutput: false` for a model
/// whose providers don't offer constrained JSON, so guided generation fails
/// fast client-side instead of decoding loosely-shaped output.
public struct OpenRouterModel: Sendable, Hashable, ExpressibleByStringLiteral {
  /// The OpenRouter model ID, e.g. `"openai/gpt-5.2"` or
  /// `"anthropic/claude-sonnet-4.5"`. Suffixes like `:nitro` and `:floor`
  /// work as they do everywhere else on OpenRouter.
  public let id: String
  public let capabilities: Capabilities

  /// - Parameter capabilities: Pass explicitly to override; when omitted,
  ///   measured per-vendor defaults apply (see `VendorDefaults`) — e.g.
  ///   `amazon/*` models don't accept `response_format` on OpenRouter, and
  ///   verified vendors skip the guide-constraint probe.
  public init(id: String, capabilities: Capabilities? = nil) {
    self.id = id
    self.capabilities = capabilities ?? VendorDefaults.capabilities(for: id)
  }

  public init(stringLiteral value: String) {
    self.init(id: value)
  }

  public struct Capabilities: Sendable, Hashable {
    /// Client-side tool calling (`tools` / `tool_calls`).
    public var toolCalling: Bool
    /// Image content parts on user messages.
    public var imageInput: Bool
    /// The `reasoning` request parameter and streamed reasoning tokens.
    public var reasoning: Bool
    /// `response_format: json_schema` structured output.
    public var structuredOutput: Bool
    /// How `@Guide` bounds (`minimum`, `minItems`, `pattern`, …) reach the
    /// wire. See ``GuideConstraints``.
    public var guideConstraints: GuideConstraints

    public init(
      toolCalling: Bool = true,
      imageInput: Bool = true,
      reasoning: Bool = true,
      structuredOutput: Bool = true,
      guideConstraints: GuideConstraints = .automatic
    ) {
      self.toolCalling = toolCalling
      self.imageInput = imageInput
      self.reasoning = reasoning
      self.structuredOutput = structuredOutput
      self.guideConstraints = guideConstraints
    }
  }

  /// Whether `@Guide` constraint keywords ship in wire schemas.
  ///
  /// A schema the provider rejects fails validation before generation, so a
  /// rejection bills no tokens — the probe costs one round trip of latency,
  /// at most once per model per process. Pin `.included` or `.stripped` when
  /// the model's behavior is known to skip probing entirely.
  public enum GuideConstraints: Sendable, Hashable {
    /// Send constraints; if the provider rejects the schema, retry once
    /// without them and remember the model for the rest of the process.
    case automatic
    /// Always send constraints and never retry — a provider that rejects
    /// them surfaces the error.
    case included
    /// Never send constraints. No probe, no retry; bounds are prompt
    /// guidance only.
    case stripped
  }
}
