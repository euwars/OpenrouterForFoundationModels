// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels

/// OpenRouter as a Foundation Models server-side language model.
///
/// ```swift
/// let model = OpenRouterLanguageModel(
///   name: "anthropic/claude-sonnet-4.5",
///   auth: .apiKey(key)
/// )
/// let session = LanguageModelSession(model: model)
/// let response = try await session.respond(to: "Plan a 4-day trip to Buenos Aires")
/// ```
///
/// Works with any OpenRouter model ID — streaming, tool calling, guided
/// generation, and reasoning all flow through the same `LanguageModelSession`
/// API used for Apple's on-device model.
public struct OpenRouterLanguageModel: Sendable {
  public let model: OpenRouterModel
  public let baseURL: URL
  public let timeout: TimeInterval
  public let reasoning: ReasoningPolicy?
  public let provider: ProviderPreferences?
  public let fallbackModels: [String]
  public let attribution: Attribution?
  public let caching: CachePolicy
  public let transforms: [String]
  public let serverTools: Set<OpenRouterServerTool>
  public let structuredOutputRetries: Int
  public let serviceTier: ServiceTier?
  public let sessionID: String?
  let authMode: AuthMode

  /// - Parameters:
  ///   - name: OpenRouter model ID. A string literal works
  ///     (`"openai/gpt-5.2"`); construct an ``OpenRouterModel`` to override
  ///     capabilities for models that lack one (e.g. no structured output).
  ///   - auth: Credential mode. `.apiKey` for development; `.proxied` with a
  ///     custom `baseURL` to route through a developer-run relay that adds
  ///     credentials server-side.
  ///   - reasoning: Pins OpenRouter's `reasoning` parameter for every
  ///     request, overriding the framework's per-request reasoning hints.
  ///     When `nil`, hints map per request (`.light` → `low`, `.moderate` →
  ///     `medium`, `.deep` → `high`).
  ///   - provider: Routing preferences — provider order, ZDR, price caps,
  ///     data-collection policy.
  ///   - fallbackModels: Model IDs OpenRouter falls back to when `name` is
  ///     unavailable or errors.
  ///   - serverTools: Tools that execute on OpenRouter's infrastructure
  ///     (web search). Distinct from the framework's `tools:` array, which
  ///     the framework invokes client-side.
  ///   - attribution: App identity for OpenRouter rankings (`HTTP-Referer`,
  ///     `X-Title`).
  ///   - caching: Prompt-cache breakpoint policy for providers that need
  ///     explicit markers (Anthropic, Gemini). `.automatic` by default.
  ///   - transforms: OpenRouter prompt transforms, e.g. `["middle-out"]`.
  ///   - structuredOutputRetries: How many times to silently re-request a
  ///     guided-generation turn whose JSON fails schema validation (some
  ///     providers aren't 100% reliable at strict structured output).
  ///     0 — the default — forwards the first attempt as-is. When enabled,
  ///     attempts buffer until valid, so partial snapshots arrive only from
  ///     the accepted attempt; each retry is logged via `os.Logger`
  ///     (subsystem `OpenRouterForFoundationModels`).
  ///   - serviceTier: Cost/latency tier (`.flex`, `.priority`, `.fast`) on
  ///     providers that offer one. Billing follows the tier that actually
  ///     serves the request; the served tier and generation cost surface on
  ///     each response transcript entry's metadata
  ///     (``OpenRouterMetadata/servedTier``, ``OpenRouterMetadata/cost``).
  ///   - sessionID: Sticky-routing key (max 256 characters). Requests with
  ///     the same ID route to the same provider endpoint, keeping prompt
  ///     caches warm across a conversation. Override per request via
  ///     ``OpenRouterMetadata/sessionID`` in `request.metadata`.
  ///   - baseURL: API endpoint. Override to point at a developer-run proxy
  ///     (use with ``AuthMode/proxied(headers:)``).
  ///   - timeout: Per-request timeout. The clock resets whenever bytes
  ///     arrive, and OpenRouter sends keep-alive comments while an upstream
  ///     model thinks, so this bounds silence, not total generation time.
  public init(
    name: OpenRouterModel,
    auth: AuthMode,
    reasoning: ReasoningPolicy? = nil,
    provider: ProviderPreferences? = nil,
    serverTools: Set<OpenRouterServerTool> = [],
    fallbackModels: [String] = [],
    attribution: Attribution? = nil,
    caching: CachePolicy = .automatic,
    transforms: [String] = [],
    structuredOutputRetries: Int = 0,
    serviceTier: ServiceTier? = nil,
    sessionID: String? = nil,
    baseURL: URL = OpenRouterLanguageModel.defaultBaseURL,
    timeout: TimeInterval = 120
  ) {
    self.model = name
    self.authMode = auth
    self.reasoning = reasoning
    self.provider = provider
    self.serverTools = serverTools
    self.fallbackModels = fallbackModels
    self.attribution = attribution
    self.caching = caching
    self.transforms = transforms
    self.structuredOutputRetries = structuredOutputRetries
    self.serviceTier = serviceTier
    self.sessionID = sessionID
    self.baseURL = baseURL
    self.timeout = timeout
  }

  public static let defaultBaseURL = URL(string: "https://openrouter.ai/api")!
}

extension OpenRouterLanguageModel: LanguageModel {
  public typealias Executor = OpenRouterExecutor

  /// Derived from the model's ``OpenRouterModel/Capabilities`` so the
  /// framework only routes work the bridge will actually send.
  public var capabilities: LanguageModelCapabilities {
    var capabilities: [LanguageModelCapabilities.Capability] = []
    if model.capabilities.toolCalling { capabilities.append(.toolCalling) }
    if model.capabilities.imageInput { capabilities.append(.vision) }
    if model.capabilities.reasoning { capabilities.append(.reasoning) }
    if model.capabilities.structuredOutput { capabilities.append(.guidedGeneration) }
    return LanguageModelCapabilities(capabilities)
  }

  public var executorConfiguration: OpenRouterExecutor.Configuration {
    .init(
      model: model,
      baseURL: baseURL,
      authMode: authMode,
      timeout: timeout,
      reasoning: reasoning,
      provider: provider,
      serverTools: serverTools,
      fallbackModels: fallbackModels,
      attribution: attribution,
      caching: caching,
      transforms: transforms,
      structuredOutputRetries: structuredOutputRetries,
      serviceTier: serviceTier,
      sessionID: sessionID
    )
  }
}
