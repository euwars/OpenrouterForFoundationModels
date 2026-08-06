// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Reasoning

/// Pins OpenRouter's `reasoning` parameter for every request.
///
/// Fixed for the life of the model value: it takes precedence over the
/// framework's per-request reasoning hints, and is the only way to express
/// a token budget, `exclude`, or effort levels the framework's reasoning
/// levels don't reach (`xhigh`, `max`, `minimal`, `none`).
///
/// When no policy is set, the framework's `reasoningLevel` maps per request:
/// `.light` → `low`, `.moderate` → `medium`, `.deep` → `high`, and `.custom`
/// accepts an OpenRouter effort name directly (`"xhigh"`, `"minimal"`, …).
public struct ReasoningPolicy: Sendable, Hashable {
  /// Effort-based control (OpenAI, Grok, and effort-mapped elsewhere).
  public enum Effort: String, Sendable, Hashable, CaseIterable {
    case none, minimal, low, medium, high, xhigh, max
  }

  public var effort: Effort?
  /// Exact reasoning-token budget (Anthropic, Gemini). Anthropic's minimum
  /// is 1024. Mutually exclusive with `effort` on the wire; when both are
  /// set, `effort` wins.
  public var maxTokens: Int?
  /// Turn reasoning on with provider defaults (`true`) or off (`false`).
  public var enabled: Bool?
  /// Model still reasons, but reasoning text is withheld from the response —
  /// you pay for the tokens without receiving them.
  public var exclude: Bool

  public init(
    effort: Effort? = nil,
    maxTokens: Int? = nil,
    enabled: Bool? = nil,
    exclude: Bool = false
  ) {
    self.effort = effort
    self.maxTokens = maxTokens
    self.enabled = enabled
    self.exclude = exclude
  }

  /// Effort-based reasoning: `.effort(.high)`.
  public static func effort(_ level: Effort, exclude: Bool = false) -> ReasoningPolicy {
    ReasoningPolicy(effort: level, exclude: exclude)
  }

  /// Budget-based reasoning: `.budget(8000)`.
  public static func budget(_ tokens: Int, exclude: Bool = false) -> ReasoningPolicy {
    ReasoningPolicy(maxTokens: tokens, exclude: exclude)
  }

  /// Reasoning on, with the provider's defaults.
  public static let enabled = ReasoningPolicy(enabled: true)

  /// Reasoning off, including for models that reason by default.
  public static let disabled = ReasoningPolicy(enabled: false)
}

// MARK: - Provider routing

/// OpenRouter provider routing preferences — which upstream endpoints may
/// serve the request and in what order. Mirrors the API's `provider` object.
public struct ProviderPreferences: Sendable, Hashable {
  /// Provider slugs to try in order (e.g. `["anthropic", "google-vertex"]`).
  public var order: [String]?
  /// Restrict routing to these provider slugs.
  public var only: [String]?
  /// Never route to these provider slugs.
  public var ignore: [String]?
  /// Whether to fall back to other providers when the preferred ones fail.
  /// OpenRouter's default is `true`.
  public var allowFallbacks: Bool?
  /// Only route to endpoints that support every parameter in the request.
  /// The bridge turns this on automatically when structured output is
  /// requested and the field is unset.
  public var requireParameters: Bool?
  public enum DataCollection: String, Sendable, Hashable {
    case allow, deny
  }
  /// Skip providers that may store or train on inputs.
  public var dataCollection: DataCollection?
  /// Acceptable quantization levels (`"fp8"`, `"int4"`, …).
  public var quantizations: [String]?
  public enum Sort: String, Sendable, Hashable {
    case price, throughput, latency
  }
  /// Explicit routing priority; disables the default load balancing.
  public var sort: Sort?
  /// Enforce Zero Data Retention endpoints only.
  public var zdr: Bool?
  /// Maximum price in credits per million tokens.
  public var maxPromptPrice: Double?
  public var maxCompletionPrice: Double?

  public init(
    order: [String]? = nil,
    only: [String]? = nil,
    ignore: [String]? = nil,
    allowFallbacks: Bool? = nil,
    requireParameters: Bool? = nil,
    dataCollection: DataCollection? = nil,
    quantizations: [String]? = nil,
    sort: Sort? = nil,
    zdr: Bool? = nil,
    maxPromptPrice: Double? = nil,
    maxCompletionPrice: Double? = nil
  ) {
    self.order = order
    self.only = only
    self.ignore = ignore
    self.allowFallbacks = allowFallbacks
    self.requireParameters = requireParameters
    self.dataCollection = dataCollection
    self.quantizations = quantizations
    self.sort = sort
    self.zdr = zdr
    self.maxPromptPrice = maxPromptPrice
    self.maxCompletionPrice = maxCompletionPrice
  }
}

// MARK: - Attribution

/// Identifies the app on OpenRouter rankings and analytics, sent as the
/// `HTTP-Referer` and `X-Title` headers. Optional but recommended — it's how
/// an app appears on openrouter.ai leaderboards.
public struct Attribution: Sendable, Hashable {
  /// The app's site or store URL (`HTTP-Referer`).
  public var siteURL: URL?
  /// The app's display name (`X-Title`).
  public var appName: String?

  public init(siteURL: URL? = nil, appName: String? = nil) {
    self.siteURL = siteURL
    self.appName = appName
  }
}

// MARK: - Service tier

/// Cost/latency tier for providers that offer one (OpenAI, Google Vertex,
/// Google AI Studio, xAI). Billing follows the tier that actually serves the
/// request; the served tier is reported on the response transcript entry's
/// metadata under ``OpenRouterMetadata/servedTier``.
public enum ServiceTier: String, Sendable, Hashable {
  /// Lower cost, higher latency and lower availability. Routing is
  /// restricted to flex endpoints — a flex request never silently falls
  /// back to a costlier standard endpoint.
  case flex
  /// Faster, higher cost. Falls back to standard endpoints (billed at their
  /// rate) when no priority endpoint succeeds.
  case priority
  /// OpenAI's "Fast mode" alias for `priority`; on Anthropic models with a
  /// fast sibling, reroutes to it.
  case fast
}

// MARK: - Caching

/// Prompt-cache breakpoint policy.
///
/// Providers that cache automatically (OpenAI, DeepSeek, Groq, …) need no
/// markers. Anthropic and Gemini require explicit `cache_control` breakpoints
/// on content blocks; under `.automatic` the bridge marks the system message
/// and the final user message each turn, so a growing conversation re-reads
/// its prefix from cache. Providers that don't use breakpoints ignore them.
public enum CachePolicy: Sendable, Hashable {
  /// Ephemeral breakpoints (~5 minute retention) on the system message and
  /// the last user message.
  case automatic
  /// Same breakpoints with extended 1-hour retention. Writes cost more;
  /// reads over a long session cost less.
  case extended
  /// No cache markers.
  case disabled
}
