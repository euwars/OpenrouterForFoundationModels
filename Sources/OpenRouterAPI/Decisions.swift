// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Body of `POST {apiRoot}/alpha/decisions`.
///
/// Mirrors OpenRouter's `DecisionsRequest` schema. Question keys are chosen
/// by the caller of this type; the public layer assigns positional keys
/// (`q0`, `q1`, …) so names can never collide.
package struct DecisionsRequest: Sendable, Hashable, Encodable {
  package var model: String
  /// A string, an object, or an array. Media parts are read only as items
  /// of a top-level array, so the public layer always puts them there.
  package var state: JSONValue
  package var questions: [String: DecisionsQuestion]
  /// The same routing object chat completions accept.
  package var provider: ProviderPreferences?
  package var sessionID: String?

  package init(
    model: String,
    state: JSONValue,
    questions: [String: DecisionsQuestion],
    provider: ProviderPreferences? = nil,
    sessionID: String? = nil
  ) {
    self.model = model
    self.state = state
    self.questions = questions
    self.provider = provider
    self.sessionID = sessionID
  }

  private enum CodingKeys: String, CodingKey {
    case model, state, questions, provider
    case sessionID = "session_id"
  }
}

/// One question, discriminated by `type` on the wire.
///
/// Instructions and criteria entries are "Text" in the spec (a string, or
/// a JSON object or array, which is how Jev reads inline images), so they
/// are `JSONValue` here even though the public layer only sends strings
/// today.
package enum DecisionsQuestion: Sendable, Hashable, Encodable {
  case noul(instructions: JSONValue, criteria: NoulCriteria?)
  /// Every key is an option. `.null` means "no guidance for this option"
  /// and must encode as JSON `null`, not be omitted: an omitted key is an
  /// option the model never sees.
  case choice(instructions: JSONValue, criteria: [String: JSONValue])
  /// Ordered levels, lowest first. The answer's `score` is a position on
  /// this index scale.
  case score(instructions: JSONValue, levels: [JSONValue])
  /// Image bounding box. Jev 1.14 only; other models answer 400.
  case box(instructions: JSONValue)

  /// Noul criteria are both-or-neither on the wire (`true` and `false` are
  /// each required inside `criteria`), so they travel as one value.
  package struct NoulCriteria: Sendable, Hashable, Encodable {
    package var whenTrue: JSONValue
    package var whenFalse: JSONValue

    package init(whenTrue: JSONValue, whenFalse: JSONValue) {
      self.whenTrue = whenTrue
      self.whenFalse = whenFalse
    }

    private enum CodingKeys: String, CodingKey {
      case whenTrue = "true"
      case whenFalse = "false"
    }
  }

  /// The instructions, for messages that name the question.
  package var instructions: JSONValue {
    switch self {
    case .noul(let instructions, _), .choice(let instructions, _),
      .score(let instructions, _), .box(let instructions):
      instructions
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type, instructions, criteria
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(instructions, forKey: .instructions)
    switch self {
    case .noul(_, let criteria):
      try c.encode("noul", forKey: .type)
      try c.encodeIfPresent(criteria, forKey: .criteria)
    case .choice(_, let criteria):
      try c.encode("choice", forKey: .type)
      try c.encode(criteria, forKey: .criteria)
    case .score(_, let levels):
      try c.encode("score", forKey: .type)
      try c.encode(levels, forKey: .criteria)
    case .box:
      try c.encode("box", forKey: .type)
    }
  }
}

/// Response of `POST {apiRoot}/alpha/decisions`.
package struct DecisionsResponse: Sendable, Hashable, Decodable {
  /// Generation ID, e.g. `gen-dec-1789738314-…`.
  package var id: String?
  /// The model that served the request. May carry a date suffix
  /// (`typesafe/jev-1.13-20260917`) the request did not name.
  package var model: String
  package var provider: String?
  package var usage: Usage
  /// Keyed by the request's question keys. The server may return keys the
  /// request did not ask; readers ignore them.
  package var answers: [String: DecisionsAnswer]

  package struct Usage: Sendable, Hashable, Decodable {
    package var inputTokens: Int
    package var outputTokens: Int
    /// USD.
    package var cost: Double?

    private enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
      case cost
    }
  }
}

/// One answer, discriminated by `type` on the wire.
package enum DecisionsAnswer: Sendable, Hashable, Decodable {
  /// Probability of yes, 0...1.
  case noul(Double)
  case choice(String, confidence: Double?, probabilities: [String: Double])
  /// `probabilities` and the spec's `legend` are keyed by level index as a
  /// string (`"0"`, `"1"`, …). The legend echoes the request's levels, so
  /// it is not decoded.
  case score(Double, confidence: Double?, probabilities: [String: Double])
  case box(Box, confidence: Double?)
  /// A `type` this client does not know. Decoding tolerates it so a new
  /// answer kind on a key nobody asked about cannot fail the response.
  case unknown(type: String)

  /// Edges as fractions of the image's size, from the top-left corner.
  package struct Box: Sendable, Hashable, Decodable {
    package var top: Double
    package var bottom: Double
    package var left: Double
    package var right: Double

    package init(top: Double, bottom: Double, left: Double, right: Double) {
      self.top = top
      self.bottom = bottom
      self.left = left
      self.right = right
    }
  }

  /// The wire `type` string, for mismatch messages.
  package var typeName: String {
    switch self {
    case .noul: "noul"
    case .choice: "choice"
    case .score: "score"
    case .box: "box"
    case .unknown(let type): type
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type, noul, choice, score, box, confidence, probabilities
  }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    func confidence() throws -> Double? {
      try c.decodeIfPresent(Double.self, forKey: .confidence)
    }
    func probabilities() throws -> [String: Double] {
      try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
    }
    switch type {
    case "noul":
      self = .noul(try c.decode(Double.self, forKey: .noul))
    case "choice":
      self = .choice(
        try c.decode(String.self, forKey: .choice),
        confidence: try confidence(),
        probabilities: try probabilities()
      )
    case "score":
      self = .score(
        try c.decode(Double.self, forKey: .score),
        confidence: try confidence(),
        probabilities: try probabilities()
      )
    case "box":
      self = .box(try c.decode(Box.self, forKey: .box), confidence: try confidence())
    default:
      self = .unknown(type: type)
    }
  }
}
