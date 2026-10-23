// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import OpenRouterAPI

/// OpenRouter's OpenAPI example request for `createApiAlphaDecisions`,
/// built with the spec's own question keys.
private let specRequest = DecisionsRequest(
  model: "typesafe/jev-1.13",
  state: [
    "customer_tier": "enterprise",
    "ticket":
      "My checkout page shows a blank screen after I click Pay. I have tried two browsers.",
  ],
  questions: [
    "is_bug": .noul(
      instructions: "Is the customer reporting a software defect?",
      criteria: .init(
        whenTrue: "The customer describes broken or unexpected product behavior.",
        whenFalse: "The customer is asking a question or requesting a feature."
      )
    ),
    "team": .choice(
      instructions: "Which team should own this ticket?",
      criteria: [
        "account": "Login, permissions, or profile issues.",
        "frontend": "Rendering, layout, or browser compatibility issues.",
        "payments": "Checkout, billing, or payment processing issues.",
      ]
    ),
    "urgency": .score(
      instructions: "How urgent is this ticket?",
      levels: [
        "Can wait for the next release", "Should be fixed this week",
        "Blocking revenue right now",
      ]
    ),
  ]
)

/// The spec's example request with keys sorted, as the client encodes it.
/// `JSONEncoder` escapes `/` by default.
private let specRequestBytes =
  #"{"model":"typesafe\/jev-1.13","questions":{"#
  + #""is_bug":{"criteria":{"false":"The customer is asking a question or requesting a feature.","true":"The customer describes broken or unexpected product behavior."},"instructions":"Is the customer reporting a software defect?","type":"noul"},"#
  + #""team":{"criteria":{"account":"Login, permissions, or profile issues.","frontend":"Rendering, layout, or browser compatibility issues.","payments":"Checkout, billing, or payment processing issues."},"instructions":"Which team should own this ticket?","type":"choice"},"#
  + #""urgency":{"criteria":["Can wait for the next release","Should be fixed this week","Blocking revenue right now"],"instructions":"How urgent is this ticket?","type":"score"}},"#
  + #""state":{"customer_tier":"enterprise","ticket":"My checkout page shows a blank screen after I click Pay. I have tried two browsers."}}"#

/// Verbatim from OpenRouter's OpenAPI example for `createApiAlphaDecisions`.
private let specResponse = Data(
  #"""
  {"answers":{
     "is_bug":{"noul":0.96,"type":"noul"},
     "team":{"choice":"payments","confidence":0.75,"probabilities":{"account":0,"frontend":0.16,"payments":0.84},"type":"choice"},
     "urgency":{"confidence":0.99,"legend":{"0":"Can wait for the next release","1":"Should be fixed this week","2":"Blocking revenue right now"},"probabilities":{"0":0,"1":0.01,"2":0.99},"score":1.99,"type":"score"}},
   "id":"gen-dec-1789738314-X5e5eKGQdvR9rblyX250","model":"typesafe/jev-1.13-20260917","provider":"TypeSafe",
   "usage":{"cost":0.000019992,"input_tokens":476,"output_tokens":70}}
  """#.utf8
)

private func answers(_ json: String) -> Data {
  Data(#"{"model":"m","usage":{"input_tokens":1,"output_tokens":0},"answers":\#(json)}"#.utf8)
}

private func client(_ transport: StubTransport, baseURL: String = "https://openrouter.ai/api")
  -> OpenRouterClient
{
  OpenRouterClient(
    configuration: .init(auth: .bearer("sk-x"), baseURL: URL(string: baseURL)!),
    transport: transport
  )
}

@Suite struct DecisionsWireTests {
  @Test(arguments: [
    ("https://openrouter.ai/api", "https://openrouter.ai/api/alpha/decisions"),
    ("https://openrouter.ai/api/", "https://openrouter.ai/api/alpha/decisions"),
    ("https://openrouter.ai/api/v1", "https://openrouter.ai/api/alpha/decisions"),
    ("https://openrouter.ai/api/v1/", "https://openrouter.ai/api/alpha/decisions"),
    ("https://relay.example.com/openrouter", "https://relay.example.com/openrouter/alpha/decisions"),
    ("https://relay.example.com/openrouter/v1", "https://relay.example.com/openrouter/alpha/decisions"),
  ])
  func `decisions hang off the API root for both base conventions`(
    base: String,
    expected: String
  ) async throws {
    let transport = StubTransport(body: answers("{}"))
    _ = try await client(transport, baseURL: base).decide(specRequest)
    #expect(transport.lastRequest?.url?.absoluteString == expected)
  }

  @Test func `the spec's example request goes out byte for byte`() async throws {
    let transport = StubTransport(body: answers("{}"))
    _ = try await client(transport).decide(specRequest, timeout: 15)
    let request = try #require(transport.lastRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.timeoutInterval == 15)
    let body = try #require(request.httpBody)
    #expect(String(decoding: body, as: UTF8.self) == specRequestBytes)
  }

  @Test func `optional criteria, null guidance, box, provider, and session encode as the spec says`()
    async throws
  {
    let transport = StubTransport(body: answers("{}"))
    _ = try await client(transport).decide(
      DecisionsRequest(
        model: "m",
        state: "x",
        questions: [
          "a": .noul(instructions: "Bug?", criteria: nil),
          "b": .choice(instructions: "Color?", criteria: ["red": .null, "blue": "Sky-like."]),
          "c": .box(instructions: "the product"),
        ],
        provider: ProviderPreferences(zdr: true),
        sessionID: "s-1"
      )
    )
    let body = try #require(transport.lastRequest?.httpBody)
    #expect(
      String(decoding: body, as: UTF8.self)
        == #"{"model":"m","provider":{"zdr":true},"questions":{"#
        + #""a":{"instructions":"Bug?","type":"noul"},"#
        + #""b":{"criteria":{"blue":"Sky-like.","red":null},"instructions":"Color?","type":"choice"},"#
        + #""c":{"instructions":"the product","type":"box"}},"#
        + #""session_id":"s-1","state":"x"}"#
    )
  }

  @Test func `the spec's example response decodes`() async throws {
    let response = try await client(StubTransport(body: specResponse)).decide(specRequest)
    #expect(response.id == "gen-dec-1789738314-X5e5eKGQdvR9rblyX250")
    #expect(response.model == "typesafe/jev-1.13-20260917")
    #expect(response.provider == "TypeSafe")
    #expect(response.usage.inputTokens == 476)
    #expect(response.usage.outputTokens == 70)
    #expect(response.usage.cost == 0.000019992)
    #expect(
      response.answers == [
        "is_bug": .noul(0.96),
        "team": .choice(
          "payments",
          confidence: 0.75,
          probabilities: ["account": 0, "frontend": 0.16, "payments": 0.84]
        ),
        "urgency": .score(
          1.99,
          confidence: 0.99,
          probabilities: ["0": 0, "1": 0.01, "2": 0.99]
        ),
      ]
    )
  }

  @Test func `an unknown answer type decodes instead of failing the response`() async throws {
    let response = try await client(
      StubTransport(
        body: answers(#"{"x":{"type":"rank","rank":["a"]},"y":{"type":"noul","noul":0.5}}"#)
      )
    ).decide(specRequest)
    #expect(response.answers == ["x": .unknown(type: "rank"), "y": .noul(0.5)])
  }

  @Test func `a box answer decodes its edges`() async throws {
    let response = try await client(
      StubTransport(
        body: answers(
          #"{"p":{"type":"box","box":{"top":0.49,"bottom":0.89,"left":0.58,"right":0.96},"confidence":0.93}}"#
        )
      )
    ).decide(specRequest)
    #expect(
      response.answers["p"]
        == .box(.init(top: 0.49, bottom: 0.89, left: 0.58, right: 0.96), confidence: 0.93)
    )
  }

  @Test func `an error envelope throws APIError`() async {
    let transport = StubTransport(
      status: 429,
      body: Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)
    )
    await #expect(throws: APIError(code: 429, message: "slow down")) {
      try await client(transport).decide(specRequest)
    }
  }
}
