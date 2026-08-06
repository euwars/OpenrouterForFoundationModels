// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import OpenRouterAPI

private func encodedJSON(_ value: some Encodable) throws -> [String: Any] {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let data = try encoder.encode(value)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct CodableTests {
  @Test func `request encodes snake_case keys`() throws {
    var request = ChatRequest(
      model: "openai/gpt-5-mini",
      messages: [.init(role: .user, content: [.text("hi")])],
      maxTokens: 1000,
      topP: 0.9,
      topK: 40,
      toolChoice: .required,
      reasoning: ReasoningConfig(effort: "high", exclude: true),
      transforms: ["middle-out"],
      stream: true
    )
    request.provider = ProviderPreferences(
      allowFallbacks: false,
      requireParameters: true,
      dataCollection: "deny",
      sort: "price",
      zdr: true,
      maxPrice: .init(prompt: 1.5)
    )
    let json = try encodedJSON(request)
    #expect(json["max_tokens"] as? Int == 1000)
    #expect(json["top_p"] as? Double == 0.9)
    #expect(json["top_k"] as? Int == 40)
    #expect(json["tool_choice"] as? String == "required")
    #expect(json["transforms"] as? [String] == ["middle-out"])
    #expect(json["stream"] as? Bool == true)
    request.serviceTier = "flex"
    request.sessionID = "abc"
    request.cacheControl = CacheControl(ttl: "1h")
    let extended = try encodedJSON(request)
    #expect(extended["service_tier"] as? String == "flex")
    #expect(extended["session_id"] as? String == "abc")
    let cache = try #require(extended["cache_control"] as? [String: Any])
    #expect(cache["type"] as? String == "ephemeral")
    #expect(cache["ttl"] as? String == "1h")
    let reasoning = try #require(json["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "high")
    #expect(reasoning["exclude"] as? Bool == true)
    let provider = try #require(json["provider"] as? [String: Any])
    #expect(provider["allow_fallbacks"] as? Bool == false)
    #expect(provider["require_parameters"] as? Bool == true)
    #expect(provider["data_collection"] as? String == "deny")
    #expect(provider["sort"] as? String == "price")
    #expect(provider["zdr"] as? Bool == true)
    #expect((provider["max_price"] as? [String: Any])?["prompt"] as? Double == 1.5)
  }

  @Test func `single plain text content collapses to a string`() throws {
    let json = try encodedJSON(ChatMessage(role: .user, content: [.text("hi")]))
    #expect(json["content"] as? String == "hi")
  }

  @Test func `cache_control keeps content as blocks`() throws {
    let json = try encodedJSON(
      ChatMessage(role: .system, content: [.text("rules", cacheControl: CacheControl())])
    )
    let parts = try #require(json["content"] as? [[String: Any]])
    #expect(parts[0]["type"] as? String == "text")
    #expect(parts[0]["text"] as? String == "rules")
    let control = try #require(parts[0]["cache_control"] as? [String: Any])
    #expect(control["type"] as? String == "ephemeral")
    #expect(control["ttl"] == nil)
  }

  @Test func `extended cache control carries a ttl`() throws {
    let json = try encodedJSON(
      ChatMessage(role: .system, content: [.text("rules", cacheControl: CacheControl(ttl: "1h"))])
    )
    let parts = try #require(json["content"] as? [[String: Any]])
    let control = try #require(parts[0]["cache_control"] as? [String: Any])
    #expect(control["ttl"] as? String == "1h")
  }

  @Test func `image parts encode as image_url blocks`() throws {
    let json = try encodedJSON(
      ChatMessage(
        role: .user,
        content: [.text("what is this?"), .imageURL("data:image/jpeg;base64,AAAA")]
      )
    )
    let parts = try #require(json["content"] as? [[String: Any]])
    #expect(parts[1]["type"] as? String == "image_url")
    let image = try #require(parts[1]["image_url"] as? [String: Any])
    #expect(image["url"] as? String == "data:image/jpeg;base64,AAAA")
  }

  @Test func `assistant message carries tool calls and reasoning_details`() throws {
    let json = try encodedJSON(
      ChatMessage(
        role: .assistant,
        toolCalls: [
          .init(id: "call_1", function: .init(name: "f", arguments: #"{"a":1}"#))
        ],
        reasoning: "hmm",
        reasoningDetails: [.object(["type": .string("reasoning.text"), "text": .string("hmm")])]
      )
    )
    #expect(json["content"] == nil)
    #expect(json["reasoning"] as? String == "hmm")
    let calls = try #require(json["tool_calls"] as? [[String: Any]])
    #expect(calls[0]["id"] as? String == "call_1")
    #expect(calls[0]["type"] as? String == "function")
    let details = try #require(json["reasoning_details"] as? [[String: Any]])
    #expect(details[0]["type"] as? String == "reasoning.text")
  }

  @Test func `tool message carries tool_call_id`() throws {
    let json = try encodedJSON(
      ChatMessage(role: .tool, content: [.text("ok")], toolCallID: "call_1")
    )
    #expect(json["role"] as? String == "tool")
    #expect(json["tool_call_id"] as? String == "call_1")
    #expect(json["content"] as? String == "ok")
  }

  @Test func `server tools nest options under parameters`() throws {
    // Golden wire shape — flat options beside `type` are silently ignored
    // by the live API, so this nesting is load-bearing.
    let json = try encodedJSON(
      ToolDefinition.serverTool(
        type: "openrouter:web_search",
        options: ["max_results": .number(3), "engine": .string("exa")]
      )
    )
    #expect(json["type"] as? String == "openrouter:web_search")
    #expect(json["max_results"] == nil)
    #expect(json["engine"] == nil)
    let parameters = try #require(json["parameters"] as? [String: Any])
    #expect(parameters["max_results"] as? Double == 3)
    #expect(parameters["engine"] as? String == "exa")
  }

  @Test func `server tools without options omit parameters`() throws {
    let json = try encodedJSON(
      ToolDefinition.serverTool(type: "openrouter:web_search", options: [:])
    )
    #expect(json["type"] as? String == "openrouter:web_search")
    #expect(json["parameters"] == nil)
  }

  @Test func `tool definitions wrap in a function envelope`() throws {
    let json = try encodedJSON(
      ToolDefinition(
        name: "get_weather",
        description: "Weather.",
        parameters: .object(["type": .string("object")])
      )
    )
    #expect(json["type"] as? String == "function")
    let function = try #require(json["function"] as? [String: Any])
    #expect(function["name"] as? String == "get_weather")
    #expect(function["description"] as? String == "Weather.")
  }

  @Test func `response_format wraps name, strict, and schema`() throws {
    let json = try encodedJSON(
      ResponseFormat(name: "plan", schema: .object(["type": .string("object")]))
    )
    #expect(json["type"] as? String == "json_schema")
    let wrapper = try #require(json["json_schema"] as? [String: Any])
    #expect(wrapper["name"] as? String == "plan")
    #expect(wrapper["strict"] as? Bool == true)
    #expect((wrapper["schema"] as? [String: Any])?["type"] as? String == "object")
  }

  @Test func `error envelope decodes with moderation metadata`() throws {
    let body = #"""
      {"error":{"code":403,"message":"flagged","metadata":{"reasons":["hate"],"flagged_input":"…","provider_name":"P","model_slug":"m"}}}
      """#
    let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(body.utf8))
    #expect(envelope.error.code == 403)
    #expect(envelope.error.moderationReasons == ["hate"])
    #expect(envelope.error.flaggedInput == "…")
    #expect(envelope.error.providerName == "P")
  }

  @Test func `error code tolerates string values`() throws {
    let body = #"{"error":{"code":"429","message":"slow down"}}"#
    let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(body.utf8))
    #expect(envelope.error.code == 429)
  }

  @Test func `non-streaming response decodes messages`() throws {
    let body = #"""
      {"id":"gen-1","model":"m","choices":[{"message":{"role":"assistant","content":"hi","reasoning":"hmm","tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2}}
      """#
    let response = try JSONDecoder().decode(ChatResponse.self, from: Data(body.utf8))
    let message = try #require(response.choices.first?.message)
    #expect(message.content == "hi")
    #expect(message.reasoning == "hmm")
    #expect(message.toolCalls?.first?.id == "c1")
    #expect(response.usage?.promptTokens == 1)
  }
}
