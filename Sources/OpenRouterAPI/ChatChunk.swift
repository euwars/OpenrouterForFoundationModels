// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One SSE chunk from a streamed chat completion.
///
/// Mid-stream failures arrive as a chunk whose top-level `error` is set (the
/// HTTP status stays 200 because headers were already sent); per-choice
/// errors surface the same envelope under `choices[].error`.
package struct ChatChunk: Sendable, Decodable {
  package var id: String?
  package var model: String?
  package var choices: [Choice]
  package var usage: Usage?
  package var error: APIError?

  private enum CodingKeys: String, CodingKey { case id, model, choices, usage, error }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id)
    model = try c.decodeIfPresent(String.self, forKey: .model)
    choices = try c.decodeIfPresent([Choice].self, forKey: .choices) ?? []
    usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
    error = try c.decodeIfPresent(APIError.self, forKey: .error)
  }

  package struct Choice: Sendable, Decodable {
    package var delta: Delta?
    package var finishReason: String?
    package var error: APIError?

    private enum CodingKeys: String, CodingKey {
      case delta, error
      case finishReason = "finish_reason"
    }
  }

  package struct Delta: Sendable, Decodable {
    package var role: String?
    package var content: String?
    /// Plaintext reasoning stream (the string alias).
    package var reasoning: String?
    /// The DeepSeek-style spelling some OpenAI-compatible upstreams use.
    /// Same content as `reasoning`; providers send one or the other.
    package var reasoningContent: String?
    /// Structured reasoning blocks, kept as raw JSON so they can be replayed
    /// verbatim on later turns.
    package var reasoningDetails: [JSONValue]?
    /// OpenAI-style streamed refusal text.
    package var refusal: String?
    /// Web-search citations and other annotations, kept as raw JSON.
    package var annotations: [JSONValue]?
    package var toolCalls: [ToolCallDelta]?

    /// Whichever reasoning-text spelling the provider used.
    package var reasoningText: String? {
      reasoning ?? reasoningContent
    }

    private enum CodingKeys: String, CodingKey {
      case role, content, reasoning, refusal, annotations
      case reasoningContent = "reasoning_content"
      case reasoningDetails = "reasoning_details"
      case toolCalls = "tool_calls"
    }
  }

  package struct ToolCallDelta: Sendable, Decodable {
    package var index: Int?
    package var id: String?
    package var function: FunctionDelta?

    package struct FunctionDelta: Sendable, Decodable {
      package var name: String?
      package var arguments: String?
    }
  }
}

/// Usage totals; OpenRouter includes them on the final chunk of a stream and
/// on every non-streaming response. `promptTokens` is the whole prompt —
/// cached tokens are the subset reported in `promptTokensDetails`.
package struct Usage: Sendable, Decodable {
  package var promptTokens: Int?
  package var completionTokens: Int?
  package var totalTokens: Int?
  /// Credits charged for this generation.
  package var cost: Double?
  package var promptTokensDetails: PromptTokensDetails?
  package var completionTokensDetails: CompletionTokensDetails?

  package struct PromptTokensDetails: Sendable, Decodable {
    package var cachedTokens: Int?
    package var cacheWriteTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case cachedTokens = "cached_tokens"
      case cacheWriteTokens = "cache_write_tokens"
    }
  }

  package struct CompletionTokensDetails: Sendable, Decodable {
    package var reasoningTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case reasoningTokens = "reasoning_tokens"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case cost
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
    case promptTokensDetails = "prompt_tokens_details"
    case completionTokensDetails = "completion_tokens_details"
  }
}

/// Non-streaming chat completion response.
package struct ChatResponse: Sendable, Decodable {
  package var id: String?
  package var model: String?
  package var choices: [Choice]
  package var usage: Usage?

  package struct Choice: Sendable, Decodable {
    package var message: Message?
    package var finishReason: String?

    private enum CodingKeys: String, CodingKey {
      case message
      case finishReason = "finish_reason"
    }
  }

  package struct Message: Sendable, Decodable {
    package var role: String?
    package var content: String?
    package var reasoning: String?
    package var reasoningContent: String?
    package var reasoningDetails: [JSONValue]?
    package var refusal: String?
    package var toolCalls: [ToolCall]?

    private enum CodingKeys: String, CodingKey {
      case role, content, reasoning, refusal
      case reasoningContent = "reasoning_content"
      case reasoningDetails = "reasoning_details"
      case toolCalls = "tool_calls"
    }
  }
}
