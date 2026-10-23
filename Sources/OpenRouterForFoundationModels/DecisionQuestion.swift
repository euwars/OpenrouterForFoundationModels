// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI

/// A question for a decision model, typed by the answer it produces.
///
/// Build one with a factory, usually as a leading-dot argument to
/// ``OpenRouterDecisionModel/decide(about:_:)``. Each question's answer
/// comes back in the same position, already typed:
///
/// ```swift
/// let (isBug, team) = try await model.decide(
///   about: .json(ticket),
///   .noul("Is the customer reporting a software defect?"),
///   .choice("Which team should own this ticket?", among: Team.allCases)
/// ).answers
/// // isBug: Double, team: ChoiceAnswer<Team>
/// ```
///
/// A question is a value: store it, reuse it across calls, or combine a
/// runtime-sized set with ``all(_:)``.
public struct DecisionQuestion<Answer: Sendable>: Sendable {
  /// The wire questions this value contributes, in order. One for each
  /// primitive; any number for ``all(_:)``.
  let asks: [DecisionsQuestion]
  /// Turns the answers to ``asks`` into `Answer`.
  ///
  /// Invariant: called with exactly `asks.count` answers, aligned with
  /// `asks`. Throws ``OpenRouterError/unexpectedAnswer(message:)`` when an
  /// answer's type or value does not fit the question as asked.
  let read: @Sendable ([DecisionsAnswer]) throws -> Answer
}

// MARK: - Noul

extension DecisionQuestion where Answer == Double {
  /// Does this condition hold? Answers the probability of yes, `0...1`.
  public static func noul(_ instructions: String) -> DecisionQuestion<Double> {
    noul(instructions, criteria: nil)
  }

  /// Does this condition hold, judged against what yes and no each mean?
  /// Answers the probability of yes, `0...1`.
  ///
  /// - Parameters:
  ///   - yes: What makes the condition true.
  ///   - no: What makes it false.
  public static func noul(
    _ instructions: String,
    yes: String,
    no: String
  ) -> DecisionQuestion<Double> {
    noul(instructions, criteria: .init(whenTrue: .string(yes), whenFalse: .string(no)))
  }

  private static func noul(
    _ instructions: String,
    criteria: DecisionsQuestion.NoulCriteria?
  ) -> DecisionQuestion<Double> {
    DecisionQuestion(asks: [.noul(instructions: .string(instructions), criteria: criteria)]) {
      answers in
      guard case .noul(let probability) = answers[0] else {
        throw mismatch(instructions, expected: "noul", got: answers[0])
      }
      return probability
    }
  }
}

// MARK: - Choice

extension DecisionQuestion {
  /// Which one of these options? Answers the chosen option as your own
  /// type, with a probability for each option.
  ///
  /// ```swift
  /// enum Team: String, CaseIterable { case account, frontend, payments }
  /// .choice("Which team should own this ticket?", among: Team.allCases)
  /// ```
  ///
  /// Each option's `rawValue` is its name on the wire. An answer naming
  /// anything else throws ``OpenRouterError/unexpectedAnswer(message:)``.
  public static func choice<Option>(
    _ instructions: String,
    among options: [Option]
  ) -> DecisionQuestion<ChoiceAnswer<Option>>
  where Option: RawRepresentable & Hashable & Sendable, Option.RawValue == String {
    choice(instructions, options.map { ($0.rawValue, $0, nil) })
  }

  /// Which one of these options, each with guidance on when it applies?
  /// A `nil` guidance offers the option without any.
  ///
  /// ```swift
  /// .choice(
  ///   "Which team should own this ticket?",
  ///   among: [
  ///     Team.account: "Login, permissions, or profile issues.",
  ///     Team.frontend: "Rendering, layout, or browser compatibility issues.",
  ///     Team.payments: nil,
  ///   ]
  /// )
  /// ```
  ///
  /// Spell each key with its type (`Team.account`) when the question is
  /// written inline in `decide`: Swift 6.2 cannot infer `.account` there.
  /// A question stored with an explicit type takes `.account`.
  public static func choice<Option>(
    _ instructions: String,
    among options: [Option: String?]
  ) -> DecisionQuestion<ChoiceAnswer<Option>>
  where Option: RawRepresentable & Hashable & Sendable, Option.RawValue == String {
    choice(instructions, options.map { ($0.key.rawValue, $0.key, $0.value) })
  }

  /// Which one of these options, named at runtime?
  public static func choice(
    _ instructions: String,
    among options: [String]
  ) -> DecisionQuestion<ChoiceAnswer<String>> {
    choice(instructions, options.map { ($0, $0, nil) })
  }

  /// Which one of these options, named at runtime, each with optional
  /// guidance?
  public static func choice(
    _ instructions: String,
    among options: [String: String?]
  ) -> DecisionQuestion<ChoiceAnswer<String>> {
    choice(instructions, options.map { ($0.key, $0.key, $0.value) })
  }

  private static func choice<Option: Hashable & Sendable>(
    _ instructions: String,
    _ options: [(name: String, option: Option, guidance: String?)]
  ) -> DecisionQuestion<ChoiceAnswer<Option>> {
    let byName = Dictionary(options.map { ($0.name, $0.option) }) { first, _ in first }
    let criteria = Dictionary(
      options.map { ($0.name, $0.guidance.map(JSONValue.string) ?? .null) }
    ) { first, _ in first }
    return DecisionQuestion<ChoiceAnswer<Option>>(
      asks: [.choice(instructions: .string(instructions), criteria: criteria)]
    ) { answers in
      guard case .choice(let name, let confidence, let probabilities) = answers[0] else {
        throw mismatch(instructions, expected: "choice", got: answers[0])
      }
      guard let choice = byName[name] else {
        throw OpenRouterError.unexpectedAnswer(
          to: instructions,
          "the answer chose \"\(name)\", which was not offered"
        )
      }
      var byOption: [Option: Double] = [:]
      for (name, probability) in probabilities {
        if let option = byName[name] { byOption[option] = probability }
      }
      return ChoiceAnswer(choice: choice, confidence: confidence, probabilities: byOption)
    }
  }
}

// MARK: - Score

extension DecisionQuestion where Answer == ScoreAnswer {
  /// Where does this fall on an ordered scale? `levels` run lowest first;
  /// the answer is a position on their index scale.
  ///
  /// ```swift
  /// .score(
  ///   "How urgent is this ticket?",
  ///   levels: ["Can wait for the next release", "Should be fixed this week", "Blocking revenue right now"]
  /// )
  /// ```
  public static func score(
    _ instructions: String,
    levels: [String]
  ) -> DecisionQuestion<ScoreAnswer> {
    DecisionQuestion(
      asks: [.score(instructions: .string(instructions), levels: levels.map(JSONValue.string))]
    ) { answers in
      guard case .score(let score, let confidence, let probabilities) = answers[0] else {
        throw mismatch(instructions, expected: "score", got: answers[0])
      }
      var byLevel: [Double] = []
      if !probabilities.isEmpty {
        byLevel = Array(repeating: 0, count: levels.count)
        for (key, probability) in probabilities {
          if let index = Int(key), byLevel.indices.contains(index) {
            byLevel[index] = probability
          }
        }
      }
      return ScoreAnswer(score: score, confidence: confidence, probabilities: byLevel)
    }
  }
}

// MARK: - Box

extension DecisionQuestion where Answer == BoxAnswer {
  /// Where in an image in the state is the thing described? Describe the
  /// target and name the image it is in.
  ///
  /// Only `typesafe/jev-1.14` and `~typesafe/jev-latest` answer box
  /// questions; other models fail the request with HTTP 400. A box comes
  /// back even when the target is absent, so pair it with a ``noul(_:)``
  /// asking whether the target is there.
  public static func box(_ instructions: String) -> DecisionQuestion<BoxAnswer> {
    DecisionQuestion(asks: [.box(instructions: .string(instructions))]) { answers in
      guard case .box(let box, let confidence) = answers[0] else {
        throw mismatch(instructions, expected: "box", got: answers[0])
      }
      return BoxAnswer(
        top: box.top,
        bottom: box.bottom,
        left: box.left,
        right: box.right,
        confidence: confidence
      )
    }
  }
}

// MARK: - Composition

extension DecisionQuestion {
  /// Asks every question in `questions` within the same request and
  /// answers them as an array in the same order. Use it for a set sized at
  /// runtime, such as one noul per tag:
  ///
  /// ```swift
  /// let (category, tagged) = try await model.decide(
  ///   about: .text(comment),
  ///   .choice("What is this comment?", among: Category.allCases),
  ///   .all(tags.map { .noul("The comment is about \($0).") })
  /// ).answers
  /// // tagged: [Double], aligned with tags
  /// ```
  public static func all<Element>(
    _ questions: [DecisionQuestion<Element>]
  ) -> DecisionQuestion<[Element]> {
    DecisionQuestion<[Element]>(asks: questions.flatMap(\.asks)) { answers in
      var rest = answers[...]
      return try questions.map { question in
        let count = question.asks.count
        defer { rest = rest.dropFirst(count) }
        return try question.read(Array(rest.prefix(count)))
      }
    }
  }
}

extension OpenRouterError {
  /// ``unexpectedAnswer(message:)`` quoting the question it is about.
  static func unexpectedAnswer(to instructions: String, _ detail: String) -> Self {
    .unexpectedAnswer(message: "\"\(instructions)\": \(detail)")
  }
}

private func mismatch(
  _ instructions: String,
  expected: String,
  got answer: DecisionsAnswer
) -> OpenRouterError {
  .unexpectedAnswer(to: instructions, "expected a \(expected) answer, got \(answer.typeName)")
}

// MARK: - Answers

/// The answer to a choice question.
public struct ChoiceAnswer<Option: Hashable & Sendable>: Sendable, Hashable {
  /// The option the model chose. Always one of the options asked.
  public let choice: Option
  /// How sure the model is, `0...1`, when it reports one.
  public let confidence: Double?
  /// Probability per option, when the model reports a distribution.
  /// Empty when it does not.
  public let probabilities: [Option: Double]
}

/// The answer to a score question.
public struct ScoreAnswer: Sendable, Hashable {
  /// Probability-weighted position on the levels' index scale, from `0`
  /// (the first level) to `levels.count - 1`. `1.99` on three levels sits
  /// almost exactly on the top one.
  public let score: Double
  /// How sure the model is, `0...1`, when it reports one.
  public let confidence: Double?
  /// Probability per level, index-aligned with the `levels` asked. Empty
  /// when the model does not report a distribution.
  public let probabilities: [Double]
}

/// The answer to a box question: edges as fractions of the image's width
/// (`left`, `right`) and height (`top`, `bottom`), from the top-left
/// corner of the image as the model saw it.
public struct BoxAnswer: Sendable, Hashable {
  public let top: Double
  public let bottom: Double
  public let left: Double
  public let right: Double
  /// How sure the model is, `0...1`, when it reports one.
  public let confidence: Double?
}
