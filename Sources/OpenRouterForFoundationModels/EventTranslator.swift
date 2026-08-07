// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI

/// Translates the chat-completions SSE chunk stream into channel events.
///
/// One translation produces at most one response entry, one reasoning entry,
/// and one tool-calls entry; their IDs are fixed at init so every event for a
/// turn targets the same entries.
struct EventTranslator: Sendable {
  let responseEntryID: String
  let reasoningEntryID: String
  let toolCallsEntryID: String

  init(
    responseEntryID: String = UUID().uuidString,
    reasoningEntryID: String = UUID().uuidString,
    toolCallsEntryID: String = UUID().uuidString
  ) {
    self.responseEntryID = responseEntryID
    self.reasoningEntryID = reasoningEntryID
    self.toolCallsEntryID = toolCallsEntryID
  }

  /// Placeholder token count for streamed content deltas. OpenRouter reports
  /// usage only on the final chunk, so no real per-delta count exists, and a
  /// count of 0 suppresses partial-snapshot delivery. Authoritative totals
  /// still arrive via `updateUsage`.
  static let deltaTokenCount = 1

  /// Relays all writes so the first-write callback is handled in one place
  /// instead of at every send site.
  private final class FirstWriteSink {
    private let sink: any GenerationEventSink
    private var pendingFirstWrite: (@Sendable () -> Void)?

    init(
      _ sink: any GenerationEventSink,
      onFirstWrite: (@Sendable () -> Void)?
    ) {
      self.sink = sink
      self.pendingFirstWrite = onFirstWrite
    }

    func send(_ event: LanguageModelExecutorGenerationChannel.Event) async {
      pendingFirstWrite?()
      pendingFirstWrite = nil
      await sink.send(event)
    }
  }

  func translate(
    _ chunks: AsyncThrowingStream<ChatChunk, Error>,
    into channel: LanguageModelExecutorGenerationChannel,
    onFirstChannelWrite: (@Sendable () -> Void)? = nil
  ) async throws {
    try await translate(
      chunks,
      into: DirectChannelSink(channel),
      onFirstChannelWrite: onFirstChannelWrite
    )
  }

  /// - Parameter onFirstChannelWrite: Invoked once, immediately before the
  ///   first write to the sink. Chunks that write nothing don't trigger it.
  func translate(
    _ chunks: AsyncThrowingStream<ChatChunk, Error>,
    into sink: any GenerationEventSink,
    onFirstChannelWrite: (@Sendable () -> Void)? = nil
  ) async throws {
    let channel = FirstWriteSink(sink, onFirstWrite: onFirstChannelWrite)
    // Per-index `id`/`name` for tool calls. The first delta for a given index
    // supplies them; later deltas at the same index typically carry only
    // argument fragments and are routed using these latched values. Argument
    // accumulation is the framework's job — each fragment forwards via
    // `.appendArguments`.
    var toolCallRouting: [Int: (id: String, name: String)] = [:]

    // `reasoning_details` accumulate across the stream and land on the
    // reasoning entry's signature at the end, JSON-encoded, so the request
    // builder can replay them verbatim on later turns — models with signed
    // or encrypted reasoning require the blocks back unmodified.
    var details = ReasoningDetailAccumulator()

    // The tier that actually served the request, when reported. Carried
    // into usage metadata so apps can verify flex/priority billing.
    var servedTier: String?

    // OpenAI-style refusals stream as `delta.refusal` text and end the turn
    // with a normal finish reason. Accumulate and fail the turn — text that
    // never arrived shouldn't decode as an empty success.
    var refusalText = ""

    for try await chunk in chunks {
      try Task.checkCancellation()

      for choice in chunk.choices {
        if let finishReason = choice.finishReason {
          switch finishReason {
          case "content_filter":
            throw LanguageModelError.guardrailViolation(
              .init(debugDescription: "The provider's content filter stopped the response.")
            )
          case "error":
            // The paired error payload arrives via the chunk/choice `error`
            // fields, which the parser throws on; this is a fallback for a
            // bare finish marker.
            throw OpenRouterError.providerFailure(
              message: "The provider ended the stream with an error."
            )
          default:
            break
          }
        }

        guard let delta = choice.delta else { continue }

        if let refusal = delta.refusal, !refusal.isEmpty {
          refusalText += refusal
        }

        if let reasoning = delta.reasoningText, !reasoning.isEmpty {
          await channel.send(
            .reasoning(
              entryID: reasoningEntryID,
              action: .appendText(reasoning, tokenCount: Self.deltaTokenCount)
            )
          )
        }

        if let reasoningDetails = delta.reasoningDetails {
          details.merge(reasoningDetails)
        }

        if let annotations = delta.annotations {
          for annotation in annotations {
            guard let segment = Self.citationSegment(from: annotation) else { continue }
            await channel.send(
              .response(
                entryID: responseEntryID,
                action: .updateCustomSegment(segment)
              )
            )
          }
        }

        if let toolCallDeltas = delta.toolCalls {
          for (position, toolCallDelta) in toolCallDeltas.enumerated() {
            let index = toolCallDelta.index ?? position
            let existing = toolCallRouting[index] ?? (id: "", name: "")
            let routing = (
              id: existing.id + (toolCallDelta.id ?? ""),
              name: existing.name + (toolCallDelta.function?.name ?? "")
            )
            toolCallRouting[index] = routing

            // Until the id and name have arrived there is nothing to route
            // argument fragments to.
            guard !routing.id.isEmpty, !routing.name.isEmpty else { continue }

            await channel.send(
              .toolCalls(
                entryID: toolCallsEntryID,
                action: .toolCall(
                  id: routing.id,
                  name: routing.name,
                  action: .appendArguments(
                    toolCallDelta.function?.arguments ?? "",
                    tokenCount: Self.deltaTokenCount
                  )
                )
              )
            )
          }
        }

        if let text = delta.content, !text.isEmpty {
          sink.recordResponseText(text)
          await channel.send(
            .response(
              entryID: responseEntryID,
              action: .appendText(text, tokenCount: Self.deltaTokenCount)
            )
          )
        }
      }

      if let tier = chunk.serviceTier {
        servedTier = tier
      }

      // Usage arrives on the final chunk. Send AFTER content so the
      // authoritative cumulative totals overwrite the per-delta placeholders.
      if let usage = chunk.usage {
        var metadata: [String: any Sendable & Codable & Equatable] = [:]
        if let cost = usage.cost {
          metadata[OpenRouterMetadata.cost] = cost
        }
        if let servedTier {
          metadata[OpenRouterMetadata.servedTier] = servedTier
        }
        if !metadata.isEmpty {
          // Cost and served tier land on the response transcript entry,
          // where apps can read them (`Transcript.Response.metadata`) —
          // the session's aggregated usage doesn't carry per-turn metadata.
          await channel.send(
            .response(entryID: responseEntryID, action: .updateMetadata(metadata))
          )
        }
        let input = LanguageModelExecutorGenerationChannel.Usage.Input(
          totalTokenCount: usage.promptTokens ?? 0,
          cachedTokenCount: usage.promptTokensDetails?.cachedTokens ?? 0
        )
        let output = LanguageModelExecutorGenerationChannel.Usage.Output(
          totalTokenCount: usage.completionTokens ?? 0,
          reasoningTokenCount: usage.completionTokensDetails?.reasoningTokens ?? 0
        )
        await channel.send(
          .response(
            entryID: responseEntryID,
            action: .updateUsage(input: input, output: output, metadata: metadata)
          )
        )
      }
    }

    if !refusalText.isEmpty {
      throw LanguageModelError.refusal(
        .init(
          explanation: refusalText,
          debugDescription: "The model refused to answer."
        )
      )
    }

    // Persist accumulated reasoning_details on the reasoning entry. This
    // also creates the entry when a model streams only encrypted reasoning
    // (no reasoning text at all) — the blocks must still replay next turn.
    if let payload = details.encodedJSON {
      await channel.send(
        .reasoning(
          entryID: reasoningEntryID,
          action: .updateMetadata([reasoningDetailsMetadataKey: true])
        )
      )
      await channel.send(
        .reasoning(
          entryID: reasoningEntryID,
          action: .updateSignature(payload, tokenCount: 0)
        )
      )
    }
  }
}

/// Where translated events land. Production writes straight to the
/// framework's channel; the structured-output retry path records events so
/// an invalid attempt can be discarded and re-tried instead of reaching the
/// framework.
protocol GenerationEventSink: AnyObject {
  func send(_ event: LanguageModelExecutorGenerationChannel.Event) async
  /// Response-text deltas, reported alongside the events they ride in —
  /// `Event` is opaque, so the recorder can't extract text from it.
  func recordResponseText(_ text: String)
}

extension GenerationEventSink {
  func recordResponseText(_ text: String) {}
}

final class DirectChannelSink: GenerationEventSink {
  private let channel: LanguageModelExecutorGenerationChannel

  init(_ channel: LanguageModelExecutorGenerationChannel) {
    self.channel = channel
  }

  func send(_ event: LanguageModelExecutorGenerationChannel.Event) async {
    await channel.send(event)
  }
}

/// Buffers a whole attempt. `structuredText` accumulates the response text
/// so it can be validated against the schema before anything reaches the
/// framework; `replay(into:)` forwards the attempt once accepted.
final class RecordingChannelSink: GenerationEventSink {
  private(set) var events: [LanguageModelExecutorGenerationChannel.Event] = []
  private(set) var structuredText = ""

  func send(_ event: LanguageModelExecutorGenerationChannel.Event) async {
    events.append(event)
  }

  func recordResponseText(_ text: String) {
    structuredText += text
  }

  func replay(into channel: LanguageModelExecutorGenerationChannel) async {
    for event in events {
      await channel.send(event)
    }
  }
}

extension EventTranslator {
  /// `{"type": "url_citation", "url_citation": {...}}` → citation segment.
  /// The URL doubles as the segment ID, so a citation repeated across deltas
  /// updates one segment instead of accumulating duplicates.
  static func citationSegment(from annotation: JSONValue) -> OpenRouterCitationSegment? {
    guard
      annotation["type"]?.stringValue == "url_citation",
      let citation = annotation["url_citation"],
      let url = citation["url"]?.stringValue
    else { return nil }
    return OpenRouterCitationSegment(
      id: url,
      content: .init(
        url: url,
        title: citation["title"]?.stringValue,
        excerpt: citation["content"]?.stringValue,
        startIndex: citation["start_index"]?.intValue,
        endIndex: citation["end_index"]?.intValue
      )
    )
  }
}

/// Accumulates streamed `reasoning_details` into whole blocks.
///
/// Blocks are keyed by their `index`; deltas for the same index concatenate
/// streamed string fields (`text`, `summary`, `data`) and take the latest
/// value for everything else (`id`, `signature`, `format`, `type`).
struct ReasoningDetailAccumulator {
  private var blocks: [Int: [String: JSONValue]] = [:]
  private var order: [Int] = []
  /// Fallback index for deltas that don't carry one.
  private var nextImplicitIndex = 0

  private static let concatenatedFields: Set<String> = ["text", "summary", "data"]

  mutating func merge(_ deltas: [JSONValue]) {
    for delta in deltas {
      guard case .object(let fields) = delta else { continue }
      let index = fields["index"]?.intValue ?? nextImplicitIndex
      nextImplicitIndex = max(nextImplicitIndex, index + 1)

      if blocks[index] == nil {
        blocks[index] = [:]
        order.append(index)
      }
      for (key, value) in fields {
        if Self.concatenatedFields.contains(key),
          case .string(let fragment) = value,
          case .string(let existing)? = blocks[index]?[key]
        {
          blocks[index]?[key] = .string(existing + fragment)
        } else if case .null = value {
          // A null never overwrites a streamed value.
          if blocks[index]?[key] == nil { blocks[index]?[key] = value }
        } else {
          blocks[index]?[key] = value
        }
      }
    }
  }

  /// The accumulated blocks in stream order, JSON-encoded, or nil when no
  /// details arrived.
  var encodedJSON: Data? {
    guard !blocks.isEmpty else { return nil }
    let array = JSONValue.array(
      order.compactMap { blocks[$0].map(JSONValue.object) }
    )
    return try? JSONEncoder().encode(array)
  }
}
