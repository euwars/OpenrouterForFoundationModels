// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import OpenRouterAPI

private func byteStream(_ text: String) -> AsyncThrowingStream<UInt8, Error> {
  AsyncThrowingStream { continuation in
    for byte in Data(text.utf8) { continuation.yield(byte) }
    continuation.finish()
  }
}

private func collect(_ text: String) async throws -> [ChatChunk] {
  var chunks: [ChatChunk] = []
  for try await chunk in SSEParser.chunks(from: byteStream(text)) {
    chunks.append(chunk)
  }
  return chunks
}

@Suite struct SSEParserTests {
  @Test func `parses data frames into chunks`() async throws {
    let body = """
      data: {"id":"gen-1","choices":[{"delta":{"content":"Hel"}}]}

      data: {"id":"gen-1","choices":[{"delta":{"content":"lo"}}]}

      data: [DONE]

      """
    let chunks = try await collect(body)
    #expect(chunks.count == 2)
    #expect(chunks[0].choices.first?.delta?.content == "Hel")
    #expect(chunks[1].choices.first?.delta?.content == "lo")
  }

  @Test func `ignores keep-alive comments`() async throws {
    let body = """
      : OPENROUTER PROCESSING

      data: {"id":"gen-1","choices":[{"delta":{"content":"hi"}}]}

      : OPENROUTER PROCESSING

      data: [DONE]

      """
    let chunks = try await collect(body)
    #expect(chunks.count == 1)
    #expect(chunks[0].choices.first?.delta?.content == "hi")
  }

  @Test func `handles CRLF line endings`() async throws {
    let body =
      "data: {\"id\":\"gen-1\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
    let chunks = try await collect(body)
    #expect(chunks.count == 1)
    #expect(chunks[0].choices.first?.delta?.content == "hi")
  }

  @Test func `emits a frame without waiting for the next one`() async throws {
    // A body with no trailing [DONE] still yields its complete frame.
    let body = "data: {\"id\":\"gen-1\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
    let chunks = try await collect(body)
    #expect(chunks.count == 1)
  }

  @Test func `throws on a mid-stream error chunk`() async throws {
    let body = """
      data: {"id":"gen-1","choices":[{"delta":{"content":"part"}}]}

      data: {"id":"gen-1","error":{"code":502,"message":"upstream died"},"choices":[{"delta":{},"finish_reason":"error"}]}

      """
    await #expect(throws: APIError.self) {
      _ = try await collect(body)
    }
  }

  @Test func `decodes reasoning and tool call deltas`() async throws {
    let body = """
      data: {"id":"gen-1","choices":[{"delta":{"reasoning":"hmm","reasoning_details":[{"type":"reasoning.text","text":"hmm","index":0}]}}]}

      data: {"id":"gen-1","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"f","arguments":"{"}}]}}]}

      data: [DONE]

      """
    let chunks = try await collect(body)
    #expect(chunks[0].choices.first?.delta?.reasoning == "hmm")
    #expect(chunks[0].choices.first?.delta?.reasoningDetails?.count == 1)
    let call = try #require(chunks[1].choices.first?.delta?.toolCalls?.first)
    #expect(call.index == 0)
    #expect(call.id == "call_1")
    #expect(call.function?.name == "f")
    #expect(call.function?.arguments == "{")
  }

  @Test func `decodes usage on the final chunk`() async throws {
    let body = """
      data: {"id":"gen-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"cost":0.0012,"prompt_tokens_details":{"cached_tokens":80},"completion_tokens_details":{"reasoning_tokens":5}}}

      data: [DONE]

      """
    let chunks = try await collect(body)
    let usage = try #require(chunks[0].usage)
    #expect(usage.promptTokens == 100)
    #expect(usage.completionTokens == 20)
    #expect(usage.cost == 0.0012)
    #expect(usage.promptTokensDetails?.cachedTokens == 80)
    #expect(usage.completionTokensDetails?.reasoningTokens == 5)
  }
}
