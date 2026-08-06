// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Request body for `POST /api/v1/chat/completions`.
///
/// OpenRouter speaks the OpenAI chat-completions dialect plus its own
/// extensions: `reasoning`, `provider` routing preferences, model fallbacks
/// (`models`), prompt `transforms`, and per-block `cache_control`.
package struct ChatRequest: Sendable, Encodable {
  package var model: String
  /// Fallback model IDs tried in order when `model` is unavailable.
  package var models: [String]?
  package var messages: [ChatMessage]
  package var maxTokens: Int?
  package var temperature: Double?
  package var topP: Double?
  package var topK: Int?
  package var seed: Int?
  package var tools: [ToolDefinition]?
  package var toolChoice: ToolChoice?
  package var responseFormat: ResponseFormat?
  package var reasoning: ReasoningConfig?
  package var provider: ProviderPreferences?
  /// Prompt transforms, e.g. `["middle-out"]`.
  package var transforms: [String]?
  /// End-user identifier for abuse detection and per-user rate limits.
  package var user: String?
  /// Cost/latency tier: `"flex"`, `"priority"`, or `"fast"` (priority alias).
  package var serviceTier: String?
  /// Sticky-routing key: subsequent requests with the same ID route to the
  /// same provider endpoint, keeping prompt caches warm. Max 256 characters.
  package var sessionID: String?
  /// Top-level automatic cache control (Anthropic-family providers): the
  /// breakpoint lands on the last cacheable block and advances as the
  /// conversation grows.
  package var cacheControl: CacheControl?
  package var stream: Bool

  package init(
    model: String,
    models: [String]? = nil,
    messages: [ChatMessage],
    maxTokens: Int? = nil,
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    seed: Int? = nil,
    tools: [ToolDefinition]? = nil,
    toolChoice: ToolChoice? = nil,
    responseFormat: ResponseFormat? = nil,
    reasoning: ReasoningConfig? = nil,
    provider: ProviderPreferences? = nil,
    transforms: [String]? = nil,
    user: String? = nil,
    serviceTier: String? = nil,
    sessionID: String? = nil,
    cacheControl: CacheControl? = nil,
    stream: Bool = false
  ) {
    self.model = model
    self.models = models
    self.messages = messages
    self.maxTokens = maxTokens
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.seed = seed
    self.tools = tools
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
    self.reasoning = reasoning
    self.provider = provider
    self.transforms = transforms
    self.user = user
    self.serviceTier = serviceTier
    self.sessionID = sessionID
    self.cacheControl = cacheControl
    self.stream = stream
  }

  private enum CodingKeys: String, CodingKey {
    case model, models, messages, temperature, seed, tools, reasoning, provider
    case transforms, user, stream
    case maxTokens = "max_tokens"
    case topP = "top_p"
    case topK = "top_k"
    case toolChoice = "tool_choice"
    case responseFormat = "response_format"
    case serviceTier = "service_tier"
    case sessionID = "session_id"
    case cacheControl = "cache_control"
  }
}

// MARK: - Messages

package struct ChatMessage: Sendable, Hashable, Encodable {
  package enum Role: String, Sendable, Hashable, Encodable {
    case system, user, assistant, tool
  }

  package var role: Role
  package var content: [ContentPart]
  package var toolCalls: [ToolCall]?
  package var toolCallID: String?
  /// Plaintext reasoning replayed on an assistant message (the string alias).
  package var reasoning: String?
  /// Structured reasoning blocks replayed verbatim — required for models with
  /// encrypted or signed reasoning (Anthropic, Gemini, OpenAI) to keep the
  /// thought chain valid across tool-use turns. Never reshape these.
  package var reasoningDetails: [JSONValue]?

  package init(
    role: Role,
    content: [ContentPart] = [],
    toolCalls: [ToolCall]? = nil,
    toolCallID: String? = nil,
    reasoning: String? = nil,
    reasoningDetails: [JSONValue]? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
    self.reasoning = reasoning
    self.reasoningDetails = reasoningDetails
  }

  private enum CodingKeys: String, CodingKey {
    case role, content, reasoning
    case toolCalls = "tool_calls"
    case toolCallID = "tool_call_id"
    case reasoningDetails = "reasoning_details"
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(role, forKey: .role)

    // A single plain text part collapses to a string — the most compatible
    // shape. A part carrying `cache_control` must stay a block, or the
    // breakpoint is lost.
    if content.count == 1, case .text(let text, cacheControl: nil) = content[0] {
      try c.encode(text, forKey: .content)
    } else if !content.isEmpty {
      try c.encode(content, forKey: .content)
    }

    try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
    try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
    try c.encodeIfPresent(reasoning, forKey: .reasoning)
    try c.encodeIfPresent(reasoningDetails, forKey: .reasoningDetails)
  }
}

package enum ContentPart: Sendable, Hashable, Encodable {
  case text(String, cacheControl: CacheControl? = nil)
  case imageURL(String)

  private enum CodingKeys: String, CodingKey {
    case type, text
    case imageURL = "image_url"
    case cacheControl = "cache_control"
  }

  private struct ImageURL: Encodable {
    var url: String
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text, let cacheControl):
      try c.encode("text", forKey: .type)
      try c.encode(text, forKey: .text)
      try c.encodeIfPresent(cacheControl, forKey: .cacheControl)
    case .imageURL(let url):
      try c.encode("image_url", forKey: .type)
      try c.encode(ImageURL(url: url), forKey: .imageURL)
    }
  }

  /// The part's cache marker, if any.
  package var cacheControl: CacheControl? {
    if case .text(_, let control) = self { return control }
    return nil
  }

  /// The same part with `cache_control` attached. Image parts can't carry
  /// breakpoints and are returned unchanged.
  package func caching(_ control: CacheControl) -> ContentPart {
    if case .text(let text, _) = self { return .text(text, cacheControl: control) }
    return self
  }
}

/// Explicit prompt-cache breakpoint for providers that need one (Anthropic,
/// Gemini). Providers with automatic caching ignore it.
package struct CacheControl: Sendable, Hashable, Encodable {
  /// Extended retention; the default (nil) is ~5 minutes.
  package var ttl: String?

  package init(ttl: String? = nil) { self.ttl = ttl }

  private enum CodingKeys: String, CodingKey { case type, ttl }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode("ephemeral", forKey: .type)
    try c.encodeIfPresent(ttl, forKey: .ttl)
  }
}

package struct ToolCall: Sendable, Hashable, Codable {
  package var id: String
  package var function: FunctionCall

  package struct FunctionCall: Sendable, Hashable, Codable {
    package var name: String
    /// JSON-encoded arguments, verbatim as the model produced them.
    package var arguments: String

    package init(name: String, arguments: String) {
      self.name = name
      self.arguments = arguments
    }
  }

  package init(id: String, function: FunctionCall) {
    self.id = id
    self.function = function
  }

  private enum CodingKeys: String, CodingKey { case id, type, function }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    function = try c.decode(FunctionCall.self, forKey: .function)
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode("function", forKey: .type)
    try c.encode(function, forKey: .function)
  }
}

// MARK: - Tools

/// One entry of the `tools` array — either a client-side function the caller
/// executes, or an OpenRouter server tool (`{"type": "openrouter:web_search",
/// ...options}`) that runs during the request.
package enum ToolDefinition: Sendable, Hashable, Encodable {
  case function(name: String, description: String, parameters: JSONValue)
  case serverTool(type: String, options: [String: JSONValue])

  package init(name: String, description: String, parameters: JSONValue) {
    self = .function(name: name, description: description, parameters: parameters)
  }

  /// The function name, for client-side tools.
  package var name: String? {
    if case .function(let name, _, _) = self { return name }
    return nil
  }

  /// The parameter schema, for client-side tools.
  package var parameters: JSONValue? {
    if case .function(_, _, let parameters) = self { return parameters }
    return nil
  }

  private enum CodingKeys: String, CodingKey { case type, function }
  private enum FunctionKeys: String, CodingKey { case name, description, parameters }

  private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  package func encode(to encoder: Encoder) throws {
    switch self {
    case .function(let name, let description, let parameters):
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode("function", forKey: .type)
      var f = c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
      try f.encode(name, forKey: .name)
      try f.encode(description, forKey: .description)
      try f.encode(parameters, forKey: .parameters)
    case .serverTool(let type, let options):
      // Server-tool options nest under `parameters` — flat options beside
      // `type` are silently ignored (verified against the live API: a flat
      // `engine: "exa"` doesn't switch engines; a nested one does).
      var c = encoder.container(keyedBy: DynamicKey.self)
      try c.encode(type, forKey: DynamicKey("type"))
      if !options.isEmpty {
        try c.encode(JSONValue.object(options), forKey: DynamicKey("parameters"))
      }
    }
  }
}

package enum ToolChoice: String, Sendable, Hashable, Encodable {
  case auto, none, required
}

// MARK: - Structured output

/// `response_format: {"type": "json_schema", "json_schema": {...}}`.
package struct ResponseFormat: Sendable, Hashable, Encodable {
  package var name: String
  package var strict: Bool
  package var schema: JSONValue

  package init(name: String, strict: Bool = true, schema: JSONValue) {
    self.name = name
    self.strict = strict
    self.schema = schema
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case jsonSchema = "json_schema"
  }
  private enum SchemaKeys: String, CodingKey { case name, strict, schema }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode("json_schema", forKey: .type)
    var s = c.nestedContainer(keyedBy: SchemaKeys.self, forKey: .jsonSchema)
    try s.encode(name, forKey: .name)
    try s.encode(strict, forKey: .strict)
    try s.encode(schema, forKey: .schema)
  }
}

// MARK: - Reasoning

/// OpenRouter's unified `reasoning` parameter. `effort` maps to effort-based
/// models (OpenAI, Grok); `max_tokens` to budget-based ones (Anthropic,
/// Gemini); OpenRouter converts between them as needed.
package struct ReasoningConfig: Sendable, Hashable, Encodable {
  package var effort: String?
  package var maxTokens: Int?
  package var enabled: Bool?
  /// Model still reasons, but reasoning text is withheld from the response.
  package var exclude: Bool?

  package init(
    effort: String? = nil,
    maxTokens: Int? = nil,
    enabled: Bool? = nil,
    exclude: Bool? = nil
  ) {
    self.effort = effort
    self.maxTokens = maxTokens
    self.enabled = enabled
    self.exclude = exclude
  }

  private enum CodingKeys: String, CodingKey {
    case effort, enabled, exclude
    case maxTokens = "max_tokens"
  }
}

// MARK: - Provider routing

/// The `provider` routing-preferences object.
package struct ProviderPreferences: Sendable, Hashable, Encodable {
  package var order: [String]?
  package var only: [String]?
  package var ignore: [String]?
  package var allowFallbacks: Bool?
  package var requireParameters: Bool?
  package var dataCollection: String?
  package var quantizations: [String]?
  package var sort: String?
  package var zdr: Bool?
  package var maxPrice: MaxPrice?

  package struct MaxPrice: Sendable, Hashable, Encodable {
    package var prompt: Double?
    package var completion: Double?

    package init(prompt: Double? = nil, completion: Double? = nil) {
      self.prompt = prompt
      self.completion = completion
    }
  }

  package init(
    order: [String]? = nil,
    only: [String]? = nil,
    ignore: [String]? = nil,
    allowFallbacks: Bool? = nil,
    requireParameters: Bool? = nil,
    dataCollection: String? = nil,
    quantizations: [String]? = nil,
    sort: String? = nil,
    zdr: Bool? = nil,
    maxPrice: MaxPrice? = nil
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
    self.maxPrice = maxPrice
  }

  private enum CodingKeys: String, CodingKey {
    case order, only, ignore, quantizations, sort, zdr
    case allowFallbacks = "allow_fallbacks"
    case requireParameters = "require_parameters"
    case dataCollection = "data_collection"
    case maxPrice = "max_price"
  }
}
