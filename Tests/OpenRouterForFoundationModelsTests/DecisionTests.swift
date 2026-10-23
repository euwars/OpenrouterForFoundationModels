// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import Testing

@testable import OpenRouterForFoundationModels

private enum Team: String, CaseIterable, Sendable {
  case account, frontend, payments
}

private struct Ticket: Encodable, Sendable {
  let customerTier: String
  let ticket: String
  let openedAt: Date

  enum CodingKeys: String, CodingKey {
    case customerTier = "customer_tier"
    case ticket
    case openedAt = "opened_at"
  }
}

private let ticket = Ticket(
  customerTier: "enterprise",
  ticket: "My checkout page shows a blank screen after I click Pay. I have tried two browsers.",
  openedAt: Date(timeIntervalSince1970: 1_792_000_000)
)

/// The OpenAPI example response, keyed by the positional names the bridge
/// sends.
private let specAnswers = Data(
  #"""
  {"answers":{
     "q0":{"noul":0.96,"type":"noul"},
     "q1":{"choice":"payments","confidence":0.75,"probabilities":{"account":0,"frontend":0.16,"payments":0.84},"type":"choice"},
     "q2":{"confidence":0.99,"legend":{"0":"Can wait for the next release","1":"Should be fixed this week","2":"Blocking revenue right now"},"probabilities":{"0":0,"1":0.01,"2":0.99},"score":1.99,"type":"score"}},
   "id":"gen-dec-1789738314-X5e5eKGQdvR9rblyX250","model":"typesafe/jev-1.13-20260917","provider":"TypeSafe",
   "usage":{"cost":0.000019992,"input_tokens":476,"output_tokens":70}}
  """#.utf8
)

private func answers(_ json: String) -> Data {
  Data(#"{"model":"m","usage":{"input_tokens":1,"output_tokens":0},"answers":\#(json)}"#.utf8)
}

/// 1×1 PNG.
private let pngPixel = Data(
  base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)!

private func model(
  _ transport: MockTransport,
  auth: AuthMode = .apiKey("sk-x"),
  provider: ProviderPreferences? = nil,
  attribution: Attribution? = nil,
  sessionID: String? = nil,
  baseURL: URL = OpenRouterLanguageModel.defaultBaseURL,
  timeout: TimeInterval = 60
) -> OpenRouterDecisionModel {
  OpenRouterDecisionModel(
    name: "typesafe/jev-1.13",
    auth: auth,
    provider: provider,
    attribution: attribution,
    sessionID: sessionID,
    baseURL: baseURL,
    timeout: timeout,
    transport: transport
  )
}

private func error(of body: () async throws -> Void) async -> (any Error)? {
  do {
    try await body()
    return nil
  } catch {
    return error
  }
}

@Suite struct DecisionTests {
  @Test func `the spec example comes back typed in the order asked`() async throws {
    let transport = MockTransport(body: specAnswers)
    let decision = try await model(transport).decide(
      about: .json(ticket),
      .noul(
        "Is the customer reporting a software defect?",
        yes: "The customer describes broken or unexpected product behavior.",
        no: "The customer is asking a question or requesting a feature."
      ),
      .choice(
        "Which team should own this ticket?",
        among: [
          Team.account: "Login, permissions, or profile issues.",
          Team.frontend: "Rendering, layout, or browser compatibility issues.",
          Team.payments: "Checkout, billing, or payment processing issues.",
        ]
      ),
      .score(
        "How urgent is this ticket?",
        levels: [
          "Can wait for the next release", "Should be fixed this week",
          "Blocking revenue right now",
        ]
      )
    )
    let (isBug, team, urgency) = decision.answers
    #expect(isBug == 0.96)
    #expect(
      team
        == ChoiceAnswer(
          choice: .payments,
          confidence: 0.75,
          probabilities: [.account: 0, .frontend: 0.16, .payments: 0.84]
        )
    )
    #expect(urgency == ScoreAnswer(score: 1.99, confidence: 0.99, probabilities: [0, 0.01, 0.99]))
    #expect(decision.servedModel == "typesafe/jev-1.13-20260917")
    #expect(decision.provider == "TypeSafe")
    #expect(decision.id == "gen-dec-1789738314-X5e5eKGQdvR9rblyX250")
    #expect(decision.inputTokens == 476)
    #expect(decision.outputTokens == 70)
    #expect(decision.cost == 0.000019992)

    let request = try #require(transport.lastRequest)
    #expect(request.url?.absoluteString == "https://openrouter.ai/api/alpha/decisions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    let body = try requestBody(of: transport)
    #expect(body["model"] as? String == "typesafe/jev-1.13")
    #expect(body["session_id"] == nil)
    #expect(body["provider"] == nil)
    let state = try #require(body["state"] as? [String: String])
    #expect(
      state == [
        "customer_tier": "enterprise",
        "ticket":
          "My checkout page shows a blank screen after I click Pay. I have tried two browsers.",
        "opened_at": "2026-10-14T17:46:40Z",
      ]
    )
    let questions = try #require(body["questions"] as? [String: [String: Any]])
    #expect(questions.keys.sorted() == ["q0", "q1", "q2"])
    #expect(questions["q0"]?["type"] as? String == "noul")
    #expect(
      questions["q0"]?["criteria"] as? [String: String] == [
        "true": "The customer describes broken or unexpected product behavior.",
        "false": "The customer is asking a question or requesting a feature.",
      ]
    )
    #expect(questions["q1"]?["type"] as? String == "choice")
    #expect(
      questions["q1"]?["criteria"] as? [String: String] == [
        "account": "Login, permissions, or profile issues.",
        "frontend": "Rendering, layout, or browser compatibility issues.",
        "payments": "Checkout, billing, or payment processing issues.",
      ]
    )
    #expect(questions["q2"]?["type"] as? String == "score")
    #expect(
      questions["q2"]?["criteria"] as? [String] == [
        "Can wait for the next release", "Should be fixed this week",
        "Blocking revenue right now",
      ]
    )
  }

  @Test func `one question returns its answer, not a tuple`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":0.2}}"#))
    let isSpam: Double = try await model(transport).decide(about: "Buy now!!!", .noul("Spam?"))
      .answers
    #expect(isSpam == 0.2)
    let body = try requestBody(of: transport)
    #expect(body["state"] as? String == "Buy now!!!")
    let questions = try #require(body["questions"] as? [String: [String: Any]])
    #expect(questions["q0"]?.keys.sorted() == ["instructions", "type"], "no criteria without yes/no")
  }

  @Test func `all asks a runtime-sized set in one request`() async throws {
    let transport = MockTransport(
      body: answers(
        #"{"q0":{"type":"choice","choice":"question"},"q1":{"type":"noul","noul":0.9},"q2":{"type":"noul","noul":0.1}}"#
      )
    )
    let tags = ["billing", "outage"]
    let (kind, tagged) = try await model(transport).decide(
      about: "Was I charged twice during the outage?",
      .choice("What is this message?", among: ["bug", "question"]),
      .all(tags.map { .noul("The message is about \($0).") })
    ).answers
    #expect(kind.choice == "question")
    #expect(kind.probabilities.isEmpty)
    #expect(tagged == [0.9, 0.1])
    #expect(transport.requests.count == 1)
    let questions = try #require(try requestBody(of: transport)["questions"] as? [String: [String: Any]])
    #expect(questions["q1"]?["instructions"] as? String == "The message is about billing.")
    #expect(questions["q2"]?["instructions"] as? String == "The message is about outage.")
  }

  @Test func `an empty all asks nothing and answers an empty array`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":0.4}}"#))
    let (spam, tagged) = try await model(transport).decide(
      about: "x",
      .noul("Spam?"),
      .all([DecisionQuestion<Double>]())
    ).answers
    #expect(spam == 0.4)
    #expect(tagged.isEmpty)
    let questions = try #require(try requestBody(of: transport)["questions"] as? [String: Any])
    #expect(questions.keys.sorted() == ["q0"])
  }

  @Test func `a choice without guidance offers every option as null`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"choice","choice":"frontend"}}"#))
    let team = try await model(transport).decide(
      about: "x",
      .choice("Team?", among: Team.allCases)
    ).answers
    #expect(team.choice == .frontend)
    let questions = try #require(try requestBody(of: transport)["questions"] as? [String: [String: Any]])
    let criteria = try #require(questions["q0"]?["criteria"] as? [String: Any])
    #expect(criteria.keys.sorted() == ["account", "frontend", "payments"])
    #expect(criteria.values.allSatisfy { $0 is NSNull })
  }

  @Test func `choice probabilities map onto the options offered`() async throws {
    let transport = MockTransport(
      body: answers(
        #"{"q0":{"type":"choice","choice":"account","confidence":0.6,"probabilities":{"account":0.7,"frontend":0.2,"legal":0.1}}}"#
      )
    )
    let team = try await model(transport).decide(
      about: "x",
      .choice("Team?", among: Team.allCases)
    ).answers
    #expect(team == ChoiceAnswer(choice: .account, confidence: 0.6, probabilities: [.account: 0.7, .frontend: 0.2]))
  }

  @Test(arguments: [
    #"{"q0":{"type":"choice","choice":"legal"}}"#,
    #"{"q0":{"type":"noul","noul":0.5}}"#,
    #"{"q0":{"type":"rank","rank":["a"]}}"#,
    #"{"other":{"type":"choice","choice":"account"}}"#,
  ])
  func `an answer that does not fit the question throws unexpectedAnswer`(json: String) async {
    let transport = MockTransport(body: answers(json))
    let thrown = await error {
      _ = try await model(transport).decide(about: "x", .choice("Which team?", among: Team.allCases))
    }
    guard case OpenRouterError.unexpectedAnswer(let message)? = thrown else {
      Issue.record("expected unexpectedAnswer, got \(String(describing: thrown))")
      return
    }
    #expect(message.contains("Which team?"))
  }

  @Test func `answers nobody asked for are ignored`() async throws {
    let transport = MockTransport(
      body: answers(
        #"{"q0":{"type":"noul","noul":0.7},"q9":{"type":"rank","rank":[]},"extra":{"type":"noul","noul":1}}"#
      )
    )
    let answer = try await model(transport).decide(about: "x", .noul("Q?")).answers
    #expect(answer == 0.7)
  }

  @Test func `score probabilities align with the levels asked`() async throws {
    let transport = MockTransport(
      body: answers(#"{"q0":{"type":"score","score":0.4,"probabilities":{"0":0.6,"2":0.4,"7":1}}}"#)
    )
    let urgency = try await model(transport).decide(
      about: "x",
      .score("Urgency?", levels: ["low", "mid", "high"])
    ).answers
    #expect(urgency == ScoreAnswer(score: 0.4, confidence: nil, probabilities: [0.6, 0, 0.4]))
  }

  @Test func `a score without a distribution has no probabilities`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"score","score":1.2}}"#))
    let urgency = try await model(transport).decide(
      about: "x",
      .score("Urgency?", levels: ["low", "mid", "high"])
    ).answers
    #expect(urgency == ScoreAnswer(score: 1.2, confidence: nil, probabilities: []))
  }

  @Test func `a box answer carries its edges`() async throws {
    let transport = MockTransport(
      body: answers(
        #"{"q0":{"type":"box","box":{"top":0.49,"bottom":0.89,"left":0.58,"right":0.96},"confidence":0.93}}"#
      )
    )
    let box = try await model(transport).decide(
      about: ["Product photo from the listing:", .image(pngPixel)],
      .box("the product in the listing photo")
    ).answers
    #expect(box == BoxAnswer(top: 0.49, bottom: 0.89, left: 0.58, right: 0.96, confidence: 0.93))
    let questions = try #require(try requestBody(of: transport)["questions"] as? [String: [String: Any]])
    #expect(questions["q0"]?["type"] as? String == "box")
    #expect(questions["q0"]?["criteria"] == nil)
  }

  @Test func `images land in the top-level state array`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":1}}"#))
    _ = try await model(transport).decide(
      about: ["Listing title: Red square sticker", [.image(pngPixel)], .json(["sku": "R-1"])],
      .noul("The photo shows the item in the title.")
    )
    let state = try #require(try requestBody(of: transport)["state"] as? [Any])
    #expect(state.count == 3, "nested lists are spliced, not nested")
    #expect(state[0] as? String == "Listing title: Red square sticker")
    let part = try #require(state[1] as? [String: Any])
    #expect(part["type"] as? String == "image_url")
    let url = try #require((part["image_url"] as? [String: Any])?["url"] as? String)
    #if canImport(CoreGraphics) && canImport(ImageIO)
    #expect(url.hasPrefix("data:image/jpeg;base64,"), "normalized like chat attachments")
    #else
    #expect(url == "data:image/png;base64,\(pngPixel.base64EncodedString())", "sent as given")
    #endif
    #expect(state[2] as? [String: String] == ["sku": "R-1"])
  }

  @Test func `a lone image is still sent as an array`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":1}}"#))
    _ = try await model(transport).decide(about: .image(pngPixel), .noul("A photo?"))
    let state = try #require(try requestBody(of: transport)["state"] as? [[String: Any]])
    #expect(state.count == 1)
    #expect(state[0]["type"] as? String == "image_url")
  }

  @Test(arguments: [
    Data("GIF89a".utf8) + Data(repeating: 0, count: 16),
    Data("not an image at all".utf8),
  ])
  func `image bytes other than PNG, JPEG, or WebP fail before any request`(bytes: Data) async {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":1}}"#))
    let thrown = await error {
      _ = try await model(transport).decide(about: ["Photo:", .image(bytes)], .noul("A photo?"))
    }
    guard case OpenRouterError.invalidDecisionRequest? = thrown else {
      Issue.record("expected invalidDecisionRequest, got \(String(describing: thrown))")
      return
    }
    #expect(transport.requests.isEmpty)
  }

  @Test func `a choice with no options fails before any request`() async {
    let transport = MockTransport(body: answers("{}"))
    let thrown = await error {
      _ = try await model(transport).decide(about: "x", .choice("Which?", among: [String]()))
    }
    guard case OpenRouterError.invalidDecisionRequest(let message)? = thrown else {
      Issue.record("expected invalidDecisionRequest, got \(String(describing: thrown))")
      return
    }
    #expect(message.contains("Which?"))
    #expect(transport.requests.isEmpty)
  }

  @Test func `a score with no levels fails before any request`() async {
    let transport = MockTransport(body: answers("{}"))
    let thrown = await error {
      _ = try await model(transport).decide(about: "x", .score("How bad?", levels: []))
    }
    guard case OpenRouterError.invalidDecisionRequest(let message)? = thrown else {
      Issue.record("expected invalidDecisionRequest, got \(String(describing: thrown))")
      return
    }
    #expect(message.contains("How bad?"))
    #expect(transport.requests.isEmpty)
  }

  @Test(arguments: [
    "https://relay.example.com/openrouter",
    "https://relay.example.com/openrouter/v1",
  ])
  func `proxied auth sends proxy and attribution headers, no bearer`(base: String) async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":1}}"#))
    _ = try await model(
      transport,
      auth: .proxied(headers: ["X-App-Secret": "s3"]),
      attribution: Attribution(siteURL: URL(string: "https://example.app"), appName: "Example"),
      baseURL: URL(string: base)!
    ).decide(about: "x", .noul("Q?"))
    let request = try #require(transport.lastRequest)
    #expect(request.url?.absoluteString == "https://relay.example.com/openrouter/alpha/decisions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "X-App-Secret") == "s3")
    #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.app")
    #expect(request.value(forHTTPHeaderField: "X-Title") == "Example")
  }

  @Test func `an empty API key fails before any request`() async {
    let transport = MockTransport(body: Data())
    let thrown = await error {
      _ = try await model(transport, auth: .apiKey("")).decide(about: "x", .noul("Q?"))
    }
    guard case OpenRouterError.missingCredential? = thrown else {
      Issue.record("expected missingCredential, got \(String(describing: thrown))")
      return
    }
    #expect(transport.requests.isEmpty)
  }

  @Test func `HTTP failures map to the bridge's typed errors`() async {
    let expectations: [(status: Int, matches: @Sendable (any Error) -> Bool)] = [
      (400, { if case OpenRouterError.api(400, "nope") = $0 { true } else { false } }),
      (401, { if case OpenRouterError.invalidCredential("nope") = $0 { true } else { false } }),
      (402, { if case OpenRouterError.insufficientCredits("nope") = $0 { true } else { false } }),
      (408, { if case LanguageModelError.timeout = $0 { true } else { false } }),
      (413, { if case LanguageModelError.contextSizeExceeded = $0 { true } else { false } }),
      (429, { if case LanguageModelError.rateLimited = $0 { true } else { false } }),
      (502, { if case OpenRouterError.providerFailure("nope") = $0 { true } else { false } }),
      (503, { if case OpenRouterError.noProviderAvailable("nope") = $0 { true } else { false } }),
    ]
    for (status, matches) in expectations {
      let transport = MockTransport(
        status: status,
        body: Data(#"{"error":{"code":\#(status),"message":"nope"}}"#.utf8)
      )
      let thrown = await error {
        _ = try await model(transport).decide(about: "x", .noul("Q?"))
      }
      #expect(thrown.map(matches) == true, "HTTP \(status) threw \(String(describing: thrown))")
    }
  }

  @Test func `provider preferences, session, and timeout ride on the request`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":1}}"#))
    _ = try await model(
      transport,
      provider: ProviderPreferences(zdr: true),
      sessionID: "conv-42",
      timeout: 15
    ).decide(about: "x", .noul("Q?"))
    let body = try requestBody(of: transport)
    #expect(body["provider"] as? [String: Bool] == ["zdr": true])
    #expect(body["session_id"] as? String == "conv-42")
    #expect(transport.lastRequest?.timeoutInterval == 15)
  }

  @Test func `the timeout defaults to 120 seconds`() async throws {
    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":1}}"#))
    _ = try await OpenRouterDecisionModel(
      name: "m",
      auth: .apiKey("sk-x"),
      transport: transport
    ).decide(about: "x", .noul("Q?"))
    #expect(transport.lastRequest?.timeoutInterval == 120)
  }

  #if canImport(CoreGraphics) && canImport(ImageIO)
  @Test func `a rotated photo is sent upright`() async throws {
    let destinationData = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(destinationData, "public.jpeg" as CFString, 1, nil)
    )
    CGImageDestinationAddImage(
      destination,
      makeTestImage(width: 40, height: 20),
      [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary
    )
    #expect(CGImageDestinationFinalize(destination))

    let transport = MockTransport(body: answers(#"{"q0":{"type":"noul","noul":1}}"#))
    _ = try await model(transport).decide(about: .image(destinationData as Data), .noul("Upright?"))
    let state = try #require(try requestBody(of: transport)["state"] as? [[String: Any]])
    let url = try #require((state.first?["image_url"] as? [String: Any])?["url"] as? String)
    let prefix = "data:image/jpeg;base64,"
    #expect(url.hasPrefix(prefix))
    let sent = try #require(Data(base64Encoded: String(url.dropFirst(prefix.count))))
    let source = try #require(CGImageSourceCreateWithData(sent as CFData, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 40)
    #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
  }
  #endif
}
