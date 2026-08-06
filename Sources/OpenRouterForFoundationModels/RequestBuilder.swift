// SPDX-License-Identifier: Apache-2.0

import Foundation
#if ServerFoundationModels
import ServerFoundationModels
#else
import FoundationModels
#endif
import OpenRouterAPI

/// Marks a reasoning entry as carrying OpenRouter `reasoning_details` in its
/// signature bytes (JSON-encoded array), replayed verbatim on later turns.
let reasoningDetailsMetadataKey = "openrouter.reasoningDetails"

/// Well-known request-metadata keys the bridge forwards to OpenRouter.
public enum OpenRouterMetadata {
  /// Set on `request.metadata` to send OpenRouter's `user` field — a stable
  /// end-user identifier for abuse detection and per-user rate limits.
  public static let user = "openrouter.user"
  /// Set on `request.metadata` to send OpenRouter's `session_id` field for
  /// this request, overriding the model's configured `sessionID`. Keeps
  /// sticky provider routing (and therefore prompt caches) pinned per
  /// conversation. Max 256 characters.
  public static let sessionID = "openrouter.sessionID"
  /// Key on the response transcript entry's metadata
  /// (`Transcript.Response.metadata`) carrying the capacity tier that
  /// served the request (`"default"`, `"flex"`, `"priority"`).
  public static let servedTier = "openrouter.serviceTier"
  /// Key on the response transcript entry's metadata carrying the credits
  /// charged for the generation.
  public static let cost = "openrouter.cost"
}

/// Pure translation: framework request → chat completions request body.
enum RequestBuilder {
  /// Output-token cap sent when the framework doesn't set one. A generation
  /// left uncapped bills up to the provider's maximum — this bounds the
  /// worst case while staying far above normal turns (and matches the
  /// Claude bridge's default). Callers raise it per request via
  /// `GenerationOptions.maximumResponseTokens`.
  static let defaultMaxTokens = 16_000
  /// How much of the schema vocabulary to put on the wire.
  ///
  /// `@Guide` bounds (`minimum`, `minItems`, `pattern`, …) are standard JSON
  /// Schema, and providers that understand them enforce them — but the
  /// strictest validators reject keywords they don't support. `.full` keeps
  /// them; `.minimal` strips down to the vocabulary every strict validator
  /// accepts. The executor tries `.full` first and falls back per model when
  /// a provider rejects the schema.
  enum SchemaFidelity: Sendable {
    case full, minimal
  }

  static func build(
    from request: LanguageModelExecutorGenerationRequest,
    configuration: OpenRouterExecutor.Configuration,
    schemaFidelity: SchemaFidelity = .full
  ) throws -> ChatRequest {
    let model = configuration.model
    var system: String?
    var messages: [ChatMessage] = []

    // Reasoning entries buffer and attach to the next assistant message —
    // OpenRouter wants a turn's reasoning on the same assistant message as
    // its tool calls or text, and `reasoning_details` must replay unmodified
    // for models with signed or encrypted reasoning.
    var pendingReasoningText = ""
    var pendingDetails: [JSONValue] = []

    func consumeReasoning() -> (text: String?, details: [JSONValue]?) {
      defer {
        pendingReasoningText = ""
        pendingDetails = []
      }
      return (
        pendingReasoningText.isEmpty ? nil : pendingReasoningText,
        pendingDetails.isEmpty ? nil : pendingDetails
      )
    }

    func flushOrphanedReasoning() {
      let (text, details) = consumeReasoning()
      guard text != nil || details != nil else { return }
      messages.append(
        ChatMessage(role: .assistant, reasoning: text, reasoningDetails: details)
      )
    }

    for entry in request.transcript {
      switch entry {
      case .instructions(let i):
        system = (system.map { $0 + "\n\n" } ?? "") + text(of: i.segments)

      case .prompt(let p):
        flushOrphanedReasoning()
        messages.append(.init(role: .user, content: try contentParts(from: p.segments)))

      case .reasoning(let r):
        // Reasoning text replays as the concatenation it streamed as.
        pendingReasoningText += text(of: r.segments, separator: "")
        // The translator stores accumulated reasoning_details as a JSON
        // array in the entry's signature bytes. Parse directly — the
        // metadata marker is advisory only, since not every backend
        // persists channel metadata onto reasoning entries.
        if let data = r.signature,
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          case .array(let details) = value
        {
          pendingDetails += details
        }

      case .toolCalls(let calls):
        let (reasoning, details) = consumeReasoning()
        messages.append(
          .init(
            role: .assistant,
            toolCalls: calls.map {
              ToolCall(
                id: $0.id,
                function: .init(name: $0.toolName, arguments: $0.arguments.jsonString)
              )
            },
            reasoning: reasoning,
            reasoningDetails: details
          )
        )

      case .toolOutput(let out):
        messages.append(
          .init(
            role: .tool,
            content: try contentParts(from: out.segments),
            toolCallID: out.id
          )
        )

      case .response(let r):
        let (reasoning, details) = consumeReasoning()
        messages.append(
          .init(
            role: .assistant,
            content: try contentParts(from: r.segments),
            reasoning: reasoning,
            reasoningDetails: details
          )
        )

      @unknown default:
        break
      }
    }
    flushOrphanedReasoning()

    // The framework records reasoning, tool calls, and response text as
    // separate transcript entries; chat completions wants them as one
    // assistant turn — a turn's `reasoning_details` must sit on the same
    // message as the tool calls it preceded.
    messages = mergingConsecutiveAssistantMessages(messages)

    let isStructured = request.schema != nil
    if let schema = request.schema {
      // Unlike reasoning, a schema is a contract, not a hint — without
      // provider-side enforcement the response may not decode at all, so
      // failing loudly beats silently dropping it.
      guard model.capabilities.structuredOutput else {
        throw LanguageModelError.unsupportedGenerationGuide(
          .init(
            schemaName: nil,
            debugDescription:
              "\(model.id) is configured without structured output (response_format json_schema)."
          )
        )
      }
      if request.contextOptions.includeSchemaInPrompt ?? true {
        let hint = "Respond with a single JSON object matching the required schema."
        system = (system.map { $0 + "\n\n" } ?? "") + hint
      }
    }

    if let system {
      messages.insert(.init(role: .system, content: [.text(system)]), at: 0)
    }

    applyCacheBreakpoints(to: &messages, policy: configuration.caching, modelID: model.id)

    let clientTools = request.enabledToolDefinitions.map {
      toolDefinition($0, fidelity: schemaFidelity)
    }
    // Server tools are sorted for a stable wire order — the prompt cache is
    // a prefix match. `tool_choice` governs only client-side function tools,
    // so it's omitted when none exist.
    let tools =
      clientTools
      + configuration.serverTools
      .sorted { $0.sortKey < $1.sortKey }
      .map(\.toolDefinition)

    var req = ChatRequest(
      model: model.id,
      models: configuration.fallbackModels.isEmpty ? nil : configuration.fallbackModels,
      messages: messages,
      maxTokens: request.generationOptions.maximumResponseTokens ?? defaultMaxTokens,
      tools: tools.isEmpty ? nil : tools,
      toolChoice: clientTools.isEmpty
        ? nil : toolChoice(for: request.generationOptions.toolCallingMode),
      reasoning: resolvedReasoning(
        fixed: configuration.reasoning,
        options: request.contextOptions,
        model: model
      ),
      provider: wireProvider(configuration.provider, requireParameters: isStructured),
      transforms: configuration.transforms.isEmpty ? nil : configuration.transforms,
      user: request.metadata[OpenRouterMetadata.user] as? String,
      serviceTier: configuration.serviceTier?.rawValue,
      sessionID: request.metadata[OpenRouterMetadata.sessionID] as? String
        ?? configuration.sessionID,
      stream: true
    )
    if configuration.caching != .disabled, isAnthropicFamily(model.id) {
      // Anthropic-family providers support automatic caching via top-level
      // cache_control: the breakpoint lands on the last cacheable block and
      // advances as the conversation grows — strictly better multi-turn
      // than fixed per-block markers.
      req.cacheControl = configuration.caching == .extended
        ? CacheControl(ttl: "1h") : CacheControl()
    }
    applySampling(request.generationOptions, to: &req)

    if let schema = request.schema {
      req.responseFormat = ResponseFormat(
        name: schemaName(of: schema),
        strict: true,
        schema: jsonSchema(from: schema, strict: true, fidelity: schemaFidelity)
      )
    }

    return req
  }

  /// The wrapper name for `response_format.json_schema`.
  private static func schemaName(of schema: GenerationSchema) -> String {
    #if ServerFoundationModels
    // ServerFoundationModels doesn't expose the root type name directly;
    // recover it from the encoded schema's title when present.
    if case .string(let title)? = JSONValue.encoded(schema)?["title"] {
      return title
    }
    return "response"
    #else
    return schema.name
    #endif
  }

  /// True when any schema on the request carries `@Guide` constraint
  /// keywords — i.e. rebuilding at `.minimal` fidelity would produce a
  /// different request. Gates the executor's schema-rejection retry.
  static func hasConstraintKeywords(_ request: ChatRequest) -> Bool {
    var schemas: [JSONValue] = []
    if let format = request.responseFormat { schemas.append(format.schema) }
    schemas.append(contentsOf: (request.tools ?? []).compactMap(\.parameters))
    return schemas.contains(where: containsConstraintKeywords)
  }

  private static func containsConstraintKeywords(_ value: JSONValue) -> Bool {
    switch value {
    case .object(let dict):
      dict.contains { key, nested in
        constraintKeys.contains(key) || containsConstraintKeywords(nested)
      }
    case .array(let values):
      values.contains(where: containsConstraintKeywords)
    default:
      false
    }
  }

  // MARK: - Schema → JSON Schema

  /// `GenerationSchema` is `Codable` and encodes as JSON Schema, but with
  /// framework-specific extension keys (`x-order`, `title`) that strict
  /// provider validators reject. Strip non-standard keys recursively.
  ///
  /// `@Guide` constraint keys (`minimum`, `minItems`, `pattern`, …) ride
  /// along at `.full` fidelity so providers that understand them enforce the
  /// bounds; `.minimal` drops them for validators that reject them.
  ///
  /// With `strict:`, objects are additionally rewritten to the shape strict
  /// modes require: every property listed in `required`, with previously
  /// optional properties made nullable so the model can still omit a value.
  static func jsonSchema(
    from schema: GenerationSchema,
    strict: Bool = false,
    fidelity: SchemaFidelity = .full
  ) -> JSONValue {
    guard let value = JSONValue.encoded(schema) else {
      return .object(["type": "object"])
    }
    return sanitize(value, strict: strict, fidelity: fidelity)
  }

  /// Keys broadly accepted by strict schema validators. Everything else is
  /// dropped — an unknown key is a hard 400 on the strictest providers.
  private static let allowedSchemaKeys: Set<String> = [
    "type", "properties", "required", "items", "enum", "const",
    "anyOf", "allOf", "oneOf", "$ref", "$defs", "definitions",
    "description", "format", "additionalProperties",
  ]

  /// The keywords `@Guide` bounds encode to (plus close relatives), kept
  /// only at `.full` fidelity.
  private static let constraintKeys: Set<String> = [
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
    "minItems", "maxItems", "minLength", "maxLength",
    "pattern", "multipleOf",
  ]

  /// Keys whose values are `{name: schema}` maps — the names are arbitrary
  /// and must be preserved; only the nested schemas are sanitized.
  private static let mapValuedKeys: Set<String> = ["properties", "$defs", "definitions"]

  private static func sanitize(
    _ value: JSONValue,
    strict: Bool,
    fidelity: SchemaFidelity
  ) -> JSONValue {
    switch value {
    case .object(let dict):
      var out: [String: JSONValue] = [:]
      for (key, v) in dict
      where allowedSchemaKeys.contains(key)
        || (fidelity == .full && constraintKeys.contains(key))
      {
        if mapValuedKeys.contains(key), case .object(let nested) = v {
          out[key] = .object(nested.mapValues { sanitize($0, strict: strict, fidelity: fidelity) })
        } else {
          out[key] = sanitize(v, strict: strict, fidelity: fidelity)
        }
      }
      // Strict validators reject `$ref` with sibling keywords — the
      // framework emits `{"$ref": ..., "description": ...}` for nested
      // @Generable properties. Keep only the reference.
      if let ref = out["$ref"], out.count > 1 {
        return .object(["$ref": ref])
      }
      if out["type"] == .string("object") {
        // Strict modes require `additionalProperties: false` on every object.
        if out["additionalProperties"] == nil {
          out["additionalProperties"] = .bool(false)
        }
        if strict, case .object(let properties)? = out["properties"] {
          // Strict modes also require every property in `required`.
          // Previously optional properties become nullable so omission
          // stays expressible as an explicit null.
          let previouslyRequired: Set<String> =
            if case .array(let names)? = out["required"] {
              Set(names.compactMap(\.stringValue))
            } else {
              []
            }
          var rewritten = properties
          for (name, property) in properties where !previouslyRequired.contains(name) {
            rewritten[name] = nullable(property)
          }
          out["properties"] = .object(rewritten)
          out["required"] = .array(properties.keys.sorted().map(JSONValue.string))
        }
      }
      return .object(out)
    case .array(let arr):
      return .array(arr.map { sanitize($0, strict: strict, fidelity: fidelity) })
    default:
      return value
    }
  }

  /// The schema, widened to also accept `null`.
  private static func nullable(_ schema: JSONValue) -> JSONValue {
    guard case .object(var dict) = schema else { return schema }
    switch dict["type"] {
    case .string(let type):
      if type != "null" {
        dict["type"] = .array([.string(type), .string("null")])
      }
      return .object(dict)
    case .array(var types):
      if !types.contains(.string("null")) {
        types.append(.string("null"))
      }
      dict["type"] = .array(types)
      return .object(dict)
    default:
      if case .array(var variants)? = dict["anyOf"] {
        let null = JSONValue.object(["type": .string("null")])
        if !variants.contains(null) { variants.append(null) }
        dict["anyOf"] = .array(variants)
        return .object(dict)
      }
      return .object(["anyOf": .array([schema, .object(["type": .string("null")])])])
    }
  }

  // MARK: - Reasoning

  private static func resolvedReasoning(
    fixed: ReasoningPolicy?,
    options: ContextOptions,
    model: OpenRouterModel
  ) -> ReasoningConfig? {
    guard model.capabilities.reasoning else { return nil }
    // A fixed policy is a contract: it wins over the framework's
    // `reasoningLevel` and ships as configured.
    if let fixed {
      return ReasoningConfig(
        effort: fixed.effort?.rawValue,
        maxTokens: fixed.effort == nil ? fixed.maxTokens : nil,
        enabled: fixed.enabled,
        exclude: fixed.exclude ? true : nil
      )
    }
    let effort: ReasoningPolicy.Effort? =
      switch options.reasoningLevel {
      case .none: nil
      case .light: .low
      case .moderate: .medium
      case .deep: .high
      // Escape hatch: a custom level naming an OpenRouter effort
      // ("xhigh", "minimal", "none") maps directly; anything else is
      // dropped — a reasoning level is a hint, not a contract.
      case .custom(let level): ReasoningPolicy.Effort(rawValue: level)
      @unknown default: nil
      }
    guard let effort else { return nil }
    return ReasoningConfig(effort: effort.rawValue)
  }

  // MARK: - Provider preferences

  /// Public preferences → wire object. When structured output is in play and
  /// the caller didn't decide, `require_parameters` turns on so routing only
  /// considers endpoints that enforce `response_format` — a schema silently
  /// ignored upstream would surface as an undecodable response.
  private static func wireProvider(
    _ preferences: OpenRouterForFoundationModels.ProviderPreferences?,
    requireParameters: Bool
  ) -> OpenRouterAPI.ProviderPreferences? {
    var wire = OpenRouterAPI.ProviderPreferences(
      order: preferences?.order,
      only: preferences?.only,
      ignore: preferences?.ignore,
      allowFallbacks: preferences?.allowFallbacks,
      requireParameters: preferences?.requireParameters,
      dataCollection: preferences?.dataCollection?.rawValue,
      quantizations: preferences?.quantizations,
      sort: preferences?.sort?.rawValue,
      zdr: preferences?.zdr
    )
    if preferences?.maxPromptPrice != nil || preferences?.maxCompletionPrice != nil {
      wire.maxPrice = .init(
        prompt: preferences?.maxPromptPrice,
        completion: preferences?.maxCompletionPrice
      )
    }
    if requireParameters, wire.requireParameters == nil {
      wire.requireParameters = true
    }
    let isEmpty =
      wire.order == nil && wire.only == nil && wire.ignore == nil
      && wire.allowFallbacks == nil && wire.requireParameters == nil
      && wire.dataCollection == nil && wire.quantizations == nil
      && wire.sort == nil && wire.zdr == nil && wire.maxPrice == nil
    return isEmpty ? nil : wire
  }

  // MARK: - Caching

  /// Anthropic-family model IDs get top-level automatic `cache_control`
  /// instead of per-block markers (including the `~anthropic/...` alias
  /// namespace).
  static func isAnthropicFamily(_ modelID: String) -> Bool {
    modelID.hasPrefix("anthropic/") || modelID.hasPrefix("~anthropic/")
  }

  /// Breakpoints go on the system message and the final user message: the
  /// system prefix is stable across turns, and marking the conversation tail
  /// lets the next turn read everything before it as a cache hit. Providers
  /// with automatic caching ignore the markers. Anthropic-family models skip
  /// these — they use top-level automatic `cache_control` instead.
  private static func applyCacheBreakpoints(
    to messages: inout [ChatMessage],
    policy: CachePolicy,
    modelID: String
  ) {
    guard !isAnthropicFamily(modelID) else { return }
    let control: CacheControl
    switch policy {
    case .disabled: return
    case .automatic: control = CacheControl()
    case .extended: control = CacheControl(ttl: "1h")
    }

    func markLastTextPart(of index: Int) {
      let isText = { (part: ContentPart) -> Bool in
        if case .text = part { return true }
        return false
      }
      guard let partIndex = messages[index].content.lastIndex(where: isText) else { return }
      messages[index].content[partIndex] = messages[index].content[partIndex].caching(control)
    }

    if let systemIndex = messages.firstIndex(where: { $0.role == .system }) {
      markLastTextPart(of: systemIndex)
    }
    if let userIndex = messages.lastIndex(where: { $0.role == .user }) {
      markLastTextPart(of: userIndex)
    }
  }

  // MARK: - Private

  /// Folds consecutive assistant messages into one — content, tool calls,
  /// and reasoning concatenated in order. Never folds across other roles.
  private static func mergingConsecutiveAssistantMessages(
    _ messages: [ChatMessage]
  ) -> [ChatMessage] {
    var out: [ChatMessage] = []
    for message in messages {
      guard message.role == .assistant, let last = out.last, last.role == .assistant else {
        out.append(message)
        continue
      }
      var merged = last
      merged.content.append(contentsOf: message.content)
      if let calls = message.toolCalls {
        merged.toolCalls = (merged.toolCalls ?? []) + calls
      }
      if let reasoning = message.reasoning {
        merged.reasoning = (merged.reasoning ?? "") + reasoning
      }
      if let details = message.reasoningDetails {
        merged.reasoningDetails = (merged.reasoningDetails ?? []) + details
      }
      out[out.count - 1] = merged
    }
    return out
  }

  private static func text(of segments: [Transcript.Segment], separator: String = "\n") -> String {
    segments.compactMap {
      switch $0 {
      case .text(let t): t.content
      case .structure(let s): s.content.jsonString
      case .attachment, .custom: nil
      @unknown default: nil
      }
    }
    .joined(separator: separator)
  }

  private static func contentParts(from segments: [Transcript.Segment]) throws -> [ContentPart] {
    try segments.compactMap { segment -> ContentPart? in
      switch segment {
      case .text(let t) where !t.content.isEmpty:
        return .text(t.content)
      case .text:
        return nil
      case .structure(let s):
        return .text(s.content.jsonString)
      case .attachment(let a):
        switch a.content {
        case .image(let image):
          return .imageURL(try dataURL(for: image))
        @unknown default:
          throw LanguageModelError.unsupportedTranscriptContent(
            .init(
              unsupportedContent: [],
              debugDescription: "Attachment type not supported by OpenRouterLanguageModel."
            )
          )
        }
      case .custom(let custom):
        // Citations are display data attached to a past response; replaying
        // them as text would corrupt the assistant's recorded words.
        if custom is OpenRouterCitationSegment { return nil }
        let text = String(describing: custom)
        return text.isEmpty ? nil : .text(text)
      @unknown default:
        return nil
      }
    }
  }

  /// Images inline as base64 JPEG data URLs — the shape every multimodal
  /// endpoint behind OpenRouter accepts. ``OpenRouterImage`` normalizes on
  /// the way: orientation baked in, downscaled to provider limits, metadata
  /// stripped by re-encoding.
  private static func dataURL(for image: Transcript.ImageAttachment) throws -> String {
    do {
      return try OpenRouterImage(
        cgImage: image.cgImage,
        orientation: image.orientation
      ).dataURL
    } catch let error as OpenRouterImage.Error {
      throw LanguageModelError.unsupportedTranscriptContent(
        .init(
          unsupportedContent: [],
          debugDescription: error.errorDescription ?? "Image could not be prepared for upload."
        )
      )
    }
  }

  private static func toolDefinition(
    _ def: Transcript.ToolDefinition,
    fidelity: SchemaFidelity
  ) -> ToolDefinition {
    ToolDefinition(
      name: def.name,
      description: def.description,
      parameters: jsonSchema(from: def.parameters, fidelity: fidelity)
    )
  }

  /// `.allowed` is the API's default — omitted rather than sent.
  private static func toolChoice(
    for mode: GenerationOptions.ToolCallingMode?
  ) -> ToolChoice? {
    guard let mode else { return nil }
    switch mode.kind {
    case .required: return .required
    case .disallowed: return ToolChoice.none
    case .allowed: return nil
    @unknown default: return nil
    }
  }

  /// Sampling is a hint. OpenRouter drops parameters an endpoint rejects
  /// (unless `require_parameters` is set), so these flow through unmodified.
  private static func applySampling(
    _ options: GenerationOptions,
    to req: inout ChatRequest
  ) {
    req.temperature = options.temperature
    // The sampling vocabulary is identical; ServerFoundationModels spells
    // the case names differently.
    #if ServerFoundationModels
    switch options.samplingMode?.kind {
    case .greedy:
      req.temperature = 0
    case .top(let k, let seed):
      req.topK = k
      req.seed = seed.map { Int(clamping: $0) }
    case .nucleus(let threshold, let seed):
      req.topP = threshold
      req.seed = seed.map { Int(clamping: $0) }
    case nil:
      break
    default:
      break
    }
    #else
    switch options.samplingMode?.kind {
    case .greedy:
      req.temperature = 0
    case .randomTopK(let k, let seed):
      req.topK = k
      req.seed = seed.map { Int(clamping: $0) }
    case .randomProbabilityThreshold(let threshold, let seed):
      req.topP = threshold
      req.seed = seed.map { Int(clamping: $0) }
    case nil:
      break
    @unknown default:
      break
    }
    #endif
  }
}
