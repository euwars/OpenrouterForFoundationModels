// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import OpenRouterAPI
import Synchronization
import os

/// Executes generation requests against OpenRouter's chat completions API.
///
/// One executor is created per unique ``Configuration`` and reused. Heavy
/// resources (the HTTP client) live here, not on ``OpenRouterLanguageModel``.
public struct OpenRouterExecutor: LanguageModelExecutor {
  public typealias Model = OpenRouterLanguageModel

  public struct Configuration: Hashable, Sendable {
    public let model: OpenRouterModel
    public let baseURL: URL
    public let authMode: AuthMode
    public let timeout: TimeInterval
    public let reasoning: ReasoningPolicy?
    public let provider: ProviderPreferences?
    public let serverTools: Set<OpenRouterServerTool>
    public let fallbackModels: [String]
    public let attribution: Attribution?
    public let caching: CachePolicy
    public let transforms: [String]
    public let structuredOutputRetries: Int
    public let serviceTier: ServiceTier?
    public let sessionID: String?

    public init(
      model: OpenRouterModel,
      baseURL: URL,
      authMode: AuthMode,
      timeout: TimeInterval,
      reasoning: ReasoningPolicy? = nil,
      provider: ProviderPreferences? = nil,
      serverTools: Set<OpenRouterServerTool> = [],
      fallbackModels: [String] = [],
      attribution: Attribution? = nil,
      caching: CachePolicy = .automatic,
      transforms: [String] = [],
      structuredOutputRetries: Int = 0,
      serviceTier: ServiceTier? = nil,
      sessionID: String? = nil
    ) {
      self.model = model
      self.baseURL = baseURL
      self.authMode = authMode
      self.timeout = timeout
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
    }
  }

  /// Remembers models whose providers rejected full-fidelity schemas, so
  /// later requests skip straight to the minimal vocabulary. Process-wide:
  /// the probe round trip is paid at most once per model per launch, across
  /// all sessions and executors.
  final class SchemaFidelityMemo: Sendable {
    static let shared = SchemaFidelityMemo()

    private let minimal = Mutex<Set<String>>([])

    func fidelity(for model: String) -> RequestBuilder.SchemaFidelity {
      minimal.withLock { $0.contains(model) } ? .minimal : .full
    }

    func recordMinimal(_ model: String) {
      minimal.withLock { _ = $0.insert(model) }
    }
  }

  private let configuration: Configuration
  private let client: OpenRouterClient
  private let fidelityMemo = SchemaFidelityMemo.shared

  public init(configuration: Configuration) {
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = configuration.timeout
    self.init(
      configuration: configuration,
      transport: URLSessionTransport(session: URLSession(configuration: sessionConfig))
    )
  }

  /// Injects the transport so the executor can be exercised without a
  /// network. The wire-auth mapping and client construction still run here.
  init(configuration: Configuration, transport: any HTTPTransport) {
    self.configuration = configuration

    let auth: OpenRouterAPI.Configuration.Auth
    switch configuration.authMode {
    case .apiKey(let key) where !key.isEmpty:
      auth = .bearer(key)
    case .apiKey, .proxied:
      auth = .none
    }
    self.client = OpenRouterClient(
      configuration: .init(auth: auth, baseURL: configuration.baseURL),
      transport: transport
    )
  }

  private static let logger = Logger(
    subsystem: "OpenRouterForFoundationModels",
    category: "OpenRouterExecutor"
  )

  public func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: OpenRouterLanguageModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    do {
      let headers = try perRequestHeaders()
      let retries = request.schema == nil ? 0 : max(0, configuration.structuredOutputRetries)

      guard retries > 0 else {
        try await performAttempt(request, headers: headers, sink: DirectChannelSink(channel))
        return
      }

      // Providers aren't 100% reliable at strict structured output. Buffer
      // each attempt, validate the JSON against the schema, and only replay
      // a conforming attempt into the framework — an invalid one is
      // discarded and retried up to the configured count.
      let validationSchema = request.schema.map {
        RequestBuilder.jsonSchema(from: $0, fidelity: .full)
      }
      let modelID = configuration.model.id
      for attempt in 0...retries {
        let recorder = RecordingChannelSink()
        try await performAttempt(request, headers: headers, sink: recorder)
        let failure = validationSchema.flatMap {
          SchemaValidator.firstViolation(in: recorder.structuredText, against: $0)
        }
        guard let failure else {
          if attempt > 0 {
            Self.logger.info(
              "structured output for \(modelID, privacy: .public) recovered on retry \(attempt)"
            )
          }
          await recorder.replay(into: channel)
          return
        }
        if attempt < retries {
          Self.logger.warning(
            "structured output from \(modelID, privacy: .public) failed validation (attempt \(attempt + 1)/\(retries + 1)): \(failure, privacy: .public) — retrying"
          )
        } else {
          // Out of retries: forward the last attempt so the framework's own
          // decode reports the failure, exactly as with retries disabled.
          Self.logger.error(
            "structured output from \(modelID, privacy: .public) still invalid after \(retries) retries: \(failure, privacy: .public) — forwarding for framework decode"
          )
          await recorder.replay(into: channel)
        }
      }
    } catch {
      throw ErrorMapper.map(error)
    }
  }

  /// One wire attempt into `sink`, including the guide-constraint fidelity
  /// fallback for models whose providers reject constraint keywords.
  private func performAttempt(
    _ request: LanguageModelExecutorGenerationRequest,
    headers: [String: String],
    sink: any GenerationEventSink
  ) async throws {
    let fidelity: RequestBuilder.SchemaFidelity =
      switch configuration.model.capabilities.guideConstraints {
      case .stripped: .minimal
      case .included: .full
      case .automatic: fidelityMemo.fidelity(for: configuration.model.id)
      }
    let chatRequest = try RequestBuilder.build(
      from: request,
      configuration: configuration,
      schemaFidelity: fidelity
    )
    let sinkWritten = Mutex(false)
    do {
      try await stream(
        chatRequest,
        headers: headers,
        into: sink,
        onFirstChannelWrite: { @Sendable in sinkWritten.withLock { $0 = true } }
      )
    } catch let error as APIError
      where error.code == 400
      && fidelity == .full
      && configuration.model.capabilities.guideConstraints == .automatic
      && RequestBuilder.hasConstraintKeywords(chatRequest)
      && !sinkWritten.withLock({ $0 })
    {
      // A provider whose strict validator rejects `@Guide` constraint
      // keywords fails before streaming anything. Retry once with the
      // minimal vocabulary and remember the model, so bounds reach
      // providers that support them without breaking the ones that don't.
      Self.logger.info(
        "provider rejected schema constraint keywords for \(self.configuration.model.id, privacy: .public); falling back to minimal schema vocabulary"
      )
      fidelityMemo.recordMinimal(configuration.model.id)
      let minimalRequest = try RequestBuilder.build(
        from: request,
        configuration: configuration,
        schemaFidelity: .minimal
      )
      try await stream(minimalRequest, headers: headers, into: sink)
    }
  }

  private func stream(
    _ chatRequest: ChatRequest,
    headers: [String: String],
    into sink: any GenerationEventSink,
    onFirstChannelWrite: (@Sendable () -> Void)? = nil
  ) async throws {
    try await EventTranslator().translate(
      client.stream(chatRequest, headers: headers),
      into: sink,
      onFirstChannelWrite: onFirstChannelWrite
    )
  }

  /// Headers merged over the client's defaults: proxy authorization under
  /// `.proxied`, plus OpenRouter app attribution. `.apiKey` rides on the
  /// client configuration; this only enforces that a key was provided.
  private func perRequestHeaders() throws -> [String: String] {
    var headers: [String: String] = [:]
    switch configuration.authMode {
    case .apiKey(let key):
      guard !key.isEmpty else { throw OpenRouterError.missingCredential }
    case .proxied(let proxyHeaders):
      headers.merge(proxyHeaders) { _, proxy in proxy }
    }
    if let attribution = configuration.attribution {
      if let url = attribution.siteURL {
        headers["HTTP-Referer"] = url.absoluteString
      }
      if let name = attribution.appName {
        headers["X-Title"] = name
      }
    }
    return headers
  }
}
