// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI

/// An OpenRouter decision model: give it state and typed questions, get
/// typed probabilistic answers back.
///
/// ```swift
/// let model = OpenRouterDecisionModel(
///   name: "perplexity/pplx-decider-flash-v1.2",
///   auth: .apiKey(key)
/// )
/// let (isBug, team, urgency) = try await model.decide(
///   about: .json(ticket),
///   .noul("Is the customer reporting a software defect?"),
///   .choice("Which team should own this ticket?", among: Team.allCases),
///   .score("How urgent is this ticket?", levels: ["Can wait", "This week", "Blocking revenue"])
/// ).answers
/// if isBug > 0.8, team.choice == .payments { page(oncall) }
/// ```
///
/// Decision models (Jev, Perplexity Decider, Cloudflare Clef, and the rest
/// of OpenRouter's `output_modalities=decisions` catalog) produce no text,
/// so they are not a `LanguageModel` and do not run in a
/// `LanguageModelSession`. Calls go to OpenRouter's Decisions endpoint.
///
/// A plain value with no connection state: create one per call site or
/// share one, either is cheap.
public struct OpenRouterDecisionModel: Sendable {
  /// OpenRouter model ID, e.g. `"typesafe/jev-1.14"` or an alias such as
  /// `"~typesafe/jev-latest"`.
  public let name: String
  public let provider: ProviderPreferences?
  public let attribution: Attribution?
  public let sessionID: String?
  public let baseURL: URL
  public let timeout: TimeInterval
  let authMode: AuthMode
  private let client: OpenRouterClient

  /// - Parameters:
  ///   - name: OpenRouter decision model ID.
  ///   - auth: Credential mode, as for ``OpenRouterLanguageModel``.
  ///   - provider: Routing preferences: provider order, ZDR,
  ///     data-collection policy, price caps.
  ///   - attribution: App identity for OpenRouter rankings.
  ///   - sessionID: Sticky-routing key (max 256 characters), sent as
  ///     `session_id`. Requests with the same ID route to the same
  ///     provider endpoint.
  ///   - baseURL: The same base ``OpenRouterLanguageModel`` takes: a host
  ///     root (`https://openrouter.ai/api`) or an OpenAI-style base ending
  ///     in `/v1`. Requests go to `alpha/decisions` beside `v1`.
  ///   - timeout: Per-request timeout.
  public init(
    name: String,
    auth: AuthMode,
    provider: ProviderPreferences? = nil,
    attribution: Attribution? = nil,
    sessionID: String? = nil,
    baseURL: URL = OpenRouterLanguageModel.defaultBaseURL,
    timeout: TimeInterval = 120
  ) {
    // The shared session plus a per-request timeout: a model value owns no
    // session, so making one per call leaks nothing.
    self.init(
      name: name,
      auth: auth,
      provider: provider,
      attribution: attribution,
      sessionID: sessionID,
      baseURL: baseURL,
      timeout: timeout,
      transport: URLSessionTransport(session: .shared)
    )
  }

  /// Injects the transport so tests run without a network. Auth mapping
  /// and client construction still run here.
  init(
    name: String,
    auth: AuthMode,
    provider: ProviderPreferences? = nil,
    attribution: Attribution? = nil,
    sessionID: String? = nil,
    baseURL: URL = OpenRouterLanguageModel.defaultBaseURL,
    timeout: TimeInterval = 120,
    transport: any HTTPTransport
  ) {
    self.name = name
    self.authMode = auth
    self.provider = provider
    self.attribution = attribution
    self.sessionID = sessionID
    self.baseURL = baseURL
    self.timeout = timeout
    self.client = OpenRouterClient(
      configuration: .init(auth: auth.clientAuth, baseURL: baseURL),
      transport: transport
    )
  }

  /// Asks every question about `state` in one request and returns the
  /// answers typed and in the order asked.
  ///
  /// One question returns its answer directly
  /// (`try await model.decide(about: s, .noul("…")).answers` is a
  /// `Double`); several return a tuple.
  ///
  /// - Throws: The bridge's usual errors for HTTP failures (see the README's
  ///   error handling: ``OpenRouterError`` for credentials, credits, and
  ///   routing; `LanguageModelError` for rate limits, timeouts, and
  ///   oversized requests); ``OpenRouterError/invalidDecisionRequest(message:)``
  ///   before any request for an image that is not PNG, JPEG, or WebP, a
  ///   choice with no options, or a score with no levels;
  ///   ``OpenRouterError/unexpectedAnswer(message:)`` when the response
  ///   cannot answer a question as asked; `EncodingError` when a
  ///   ``DecisionState/json(_:)`` value fails to encode.
  public func decide<each Answer>(
    about state: DecisionState,
    _ questions: repeat DecisionQuestion<each Answer>
  ) async throws -> Decision<repeat each Answer> {
    do {
      let headers = try authMode.requestHeaders(attribution: attribution)
      var asks: [DecisionsQuestion] = []
      for question in repeat each questions {
        asks.append(contentsOf: question.asks)
      }
      try Self.validate(asks)
      // Positional keys: no caller-supplied name can collide, and the
      // answers map back by position alone.
      let keys = asks.indices.map { "q\($0)" }
      let response = try await client.decide(
        DecisionsRequest(
          model: name,
          state: try state.wireValue(),
          questions: Dictionary(uniqueKeysWithValues: zip(keys, asks)),
          provider: RequestBuilder.wireProvider(provider, requireParameters: false),
          sessionID: sessionID
        ),
        headers: headers,
        timeout: timeout
      )
      let cursor = try AnswerCursor(asks: asks, keys: keys, answers: response.answers)
      // The pack expansion stays inline in the initializer call: binding it
      // to a local first crashes SILGen on Swift 6.2 and 6.4.
      return Decision(
        answers: (repeat try cursor.next(each questions)),
        servedModel: response.model,
        provider: response.provider,
        id: response.id,
        inputTokens: response.usage.inputTokens,
        outputTokens: response.usage.outputTokens,
        cost: response.usage.cost
      )
    } catch {
      throw ErrorMapper.map(error)
    }
  }

  private static func validate(_ asks: [DecisionsQuestion]) throws {
    for ask in asks {
      switch ask {
      case .choice(let instructions, let criteria) where criteria.isEmpty:
        throw OpenRouterError.invalidDecisionRequest(
          message: "\"\(instructions.quoted)\": a choice needs at least one option."
        )
      case .score(let instructions, let levels) where levels.isEmpty:
        throw OpenRouterError.invalidDecisionRequest(
          message: "\"\(instructions.quoted)\": a score needs at least one level."
        )
      default:
        break
      }
    }
  }
}

/// The typed answers to one ``OpenRouterDecisionModel/decide(about:_:)``
/// call, plus what it cost.
public struct Decision<each Answer: Sendable>: Sendable {
  /// One answer per question, in the order asked. A single question's
  /// answer is the value itself, not a one-element tuple.
  public let answers: (repeat each Answer)
  /// The model that served the request. May differ from the requested
  /// name by an alias resolution or a date suffix
  /// (`typesafe/jev-1.13-20260917`).
  public let servedModel: String
  /// The provider that served the request, when OpenRouter reports it.
  public let provider: String?
  /// OpenRouter's generation ID, for support and log lookup.
  public let id: String?
  /// Billed input tokens.
  public let inputTokens: Int
  /// Output tokens as OpenRouter reports them. Decision models price
  /// output at zero.
  public let outputTokens: Int
  /// What the request cost, in USD, when OpenRouter reports it.
  public let cost: Double?
}

/// Hands each question its slice of the response, in request order.
///
/// A class so the pack expansion in `decide` can advance it without
/// capturing a mutable local. Lives only for one `decide` call.
final class AnswerCursor {
  private var remaining: ArraySlice<DecisionsAnswer>

  /// Resolves `keys` against `answers`. Keys the request did not send are
  /// ignored.
  ///
  /// - Throws: ``OpenRouterError/unexpectedAnswer(message:)`` naming the
  ///   first question with no answer, quoting its instructions.
  init(
    asks: [DecisionsQuestion],
    keys: [String],
    answers: [String: DecisionsAnswer]
  ) throws {
    var resolved: [DecisionsAnswer] = []
    for (ask, key) in zip(asks, keys) {
      guard let answer = answers[key] else {
        throw OpenRouterError.unexpectedAnswer(to: ask.instructions.quoted, "no answer came back")
      }
      resolved.append(answer)
    }
    remaining = resolved[...]
  }

  /// Passes `question` the next `question.asks.count` answers.
  func next<Answer>(_ question: DecisionQuestion<Answer>) throws -> Answer {
    let count = question.asks.count
    let slice = Array(remaining.prefix(count))
    remaining = remaining.dropFirst(count)
    return try question.read(slice)
  }
}

extension JSONValue {
  /// The text of a string, or the JSON of anything else, for messages.
  fileprivate var quoted: String { stringValue ?? jsonText }
}
