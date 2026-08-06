// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import OpenRouterAPI
import Testing

@testable import OpenRouterForFoundationModels

@Suite struct RequestBuilderTests {
  @Test func `instructions become the system message`() throws {
    let transcript = Transcript(entries: [
      .instructions(.init(segments: [.text(.init(content: "Be concise."))], toolDefinitions: [])),
      .prompt(.init(segments: [.text(.init(content: "Hello"))])),
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make()
    )
    #expect(request.messages.count == 2)
    #expect(request.messages[0].role == .system)
    #expect(request.messages[0].content == [.text("Be concise.")])
    #expect(request.messages[1].role == .user)
    #expect(request.messages[1].content == [.text("Hello")])
    #expect(request.stream)
  }

  @Test func `multi-turn entries map to alternating messages`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "Hello!"))])),
      .prompt(.init(segments: [.text(.init(content: "What's the weather?"))])),
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make()
    )
    #expect(request.messages.map(\.role) == [.user, .assistant, .user])
  }

  @Test func `tool calls and outputs round-trip`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather in SF?"))])),
      .toolCalls(
        .init([
          .init(
            id: "call_1",
            toolName: "getWeather",
            arguments: try GeneratedContent(json: #"{"city":"SF"}"#)
          )
        ])
      ),
      .toolOutput(
        .init(
          id: "call_1",
          toolName: "getWeather",
          segments: [.text(.init(content: "72F sunny"))]
        )
      ),
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make()
    )
    #expect(request.messages.count == 3)
    let assistant = request.messages[1]
    #expect(assistant.role == .assistant)
    let call = try #require(assistant.toolCalls?.first)
    #expect(call.id == "call_1")
    #expect(call.function.name == "getWeather")
    #expect(call.function.arguments.contains(#""city""#))
    let tool = request.messages[2]
    #expect(tool.role == .tool)
    #expect(tool.toolCallID == "call_1")
    #expect(tool.content == [.text("72F sunny")])
  }

  @Test func `reasoning attaches to the same assistant message as its tool calls`() throws {
    let details = JSONValue.array([
      .object([
        "type": .string("reasoning.text"),
        "text": .string("I should check."),
        "index": .number(0),
      ])
    ])
    let payload = try JSONEncoder().encode(details)
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather in SF?"))])),
      .reasoning(
        .init(
          metadata: [reasoningDetailsMetadataKey: true],
          segments: [.text(.init(content: "I should check."))],
          signature: payload
        )
      ),
      .toolCalls(
        .init([
          .init(
            id: "call_1",
            toolName: "getWeather",
            arguments: try GeneratedContent(json: #"{"city":"SF"}"#)
          )
        ])
      ),
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make()
    )
    #expect(request.messages.count == 2)
    let assistant = request.messages[1]
    #expect(assistant.role == .assistant)
    #expect(assistant.reasoning == "I should check.")
    #expect(assistant.toolCalls?.count == 1)
    // Details replay verbatim, on the same message as the calls.
    #expect(assistant.reasoningDetails == [
      .object([
        "type": .string("reasoning.text"),
        "text": .string("I should check."),
        "index": .number(0),
      ])
    ])
  }

  @Test func `reasoning without details attaches as plain text to the next response`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      .reasoning(.init(segments: [.text(.init(content: "hmm"))])),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "Hello!"))])),
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make()
    )
    #expect(request.messages.count == 2)
    #expect(request.messages[1].reasoning == "hmm")
    #expect(request.messages[1].reasoningDetails == nil)
    #expect(request.messages[1].content == [.text("Hello!")])
  }

  @Test func `enabled tools become sanitized function definitions`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        enabledTools: [
          .init(
            name: "getWeather",
            description: "Returns weather.",
            parameters: TestArgs.generationSchema
          )
        ]
      ),
      configuration: .make()
    )
    let tool = try #require(request.tools?.first)
    #expect(tool.name == "getWeather")
    guard case .object(let schema)? = tool.parameters,
      case .object(let props)? = schema["properties"]
    else {
      Issue.record("expected object schema with properties")
      return
    }
    #expect(props["city"] != nil)
    #expect(schema["additionalProperties"] == .bool(false))
    let json = try #require(tool.parameters).jsonText
    #expect(!json.contains("x-order"))
    #expect(!json.contains(#""title":"#))
  }

  @Test func `schema becomes strict response_format with all-required nullable properties`()
    throws
  {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        schema: OptionalArgs.generationSchema
      ),
      configuration: .make()
    )
    let format = try #require(request.responseFormat)
    #expect(format.strict)
    guard case .object(let schema) = format.schema,
      case .object(let props)? = schema["properties"],
      case .array(let required)? = schema["required"]
    else {
      Issue.record("expected object schema")
      return
    }
    // Strict mode: every property required, previously optional ones nullable.
    #expect(Set(required.compactMap(\.stringValue)) == ["city", "nickname"])
    guard case .object(let nickname)? = props["nickname"] else {
      Issue.record("expected nickname property")
      return
    }
    let type = nickname["type"] ?? nickname["anyOf"] ?? .null
    #expect(type.jsonText.contains("null"))
    // The required property keeps its plain type.
    guard case .object(let city)? = props["city"] else {
      Issue.record("expected city property")
      return
    }
    #expect(city["type"] == .string("string") || city["type"]?.jsonText.contains("null") == false)
    // Structured output routes only to endpoints that enforce it.
    #expect(request.provider?.requireParameters == true)
  }

  @Test func `nested schema references strip sibling keywords`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        schema: NestedArgs.generationSchema
      ),
      configuration: .make()
    )
    let format = try #require(request.responseFormat)
    guard case .object(let schema) = format.schema,
      case .object(let props)? = schema["properties"],
      case .object(let inner)? = props["inner"]
    else {
      Issue.record("expected nested schema")
      return
    }
    // Strict validators reject $ref alongside description etc.
    if inner["$ref"] != nil {
      #expect(inner.count == 1)
    }
  }

  @Test func `full fidelity keeps guide constraint keywords`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        enabledTools: [
          .init(name: "t", description: "d", parameters: BoundedArgs.generationSchema)
        ],
        schema: BoundedArgs.generationSchema
      ),
      configuration: .make(),
      schemaFidelity: .full
    )
    let schemaJSON = try #require(request.responseFormat?.schema.jsonText)
    #expect(schemaJSON.contains(#""minimum":1"#))
    #expect(schemaJSON.contains(#""maximum":5"#))
    #expect(schemaJSON.contains(#""minItems":2"#))
    #expect(schemaJSON.contains(#""pattern":"#))
    let toolJSON = try #require(request.tools?.first?.parameters?.jsonText)
    #expect(toolJSON.contains(#""minimum":1"#))
    #expect(RequestBuilder.hasConstraintKeywords(request))
  }

  @Test func `minimal fidelity strips guide constraint keywords`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        schema: BoundedArgs.generationSchema
      ),
      configuration: .make(),
      schemaFidelity: .minimal
    )
    let schemaJSON = try #require(request.responseFormat?.schema.jsonText)
    #expect(!schemaJSON.contains("minimum"))
    #expect(!schemaJSON.contains("minItems"))
    #expect(!schemaJSON.contains("pattern"))
    // The properties themselves survive.
    #expect(schemaJSON.contains(#""days":"#))
    #expect(!RequestBuilder.hasConstraintKeywords(request))
  }

  @Test func `structured output throws on models configured without it`() throws {
    let model = OpenRouterModel(
      id: "test/model",
      capabilities: .init(structuredOutput: false)
    )
    #expect(throws: LanguageModelError.self) {
      _ = try RequestBuilder.build(
        from: .make(
          transcript: Transcript(entries: [
            .prompt(.init(segments: [.text(.init(content: "Hi"))]))
          ]),
          schema: TestArgs.generationSchema
        ),
        configuration: .make(model: model)
      )
    }
  }

  @Test func `fixed reasoning policy wins over framework hints`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .light
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        contextOptions: contextOptions
      ),
      configuration: .make(reasoning: .effort(.xhigh))
    )
    #expect(request.reasoning?.effort == "xhigh")
  }

  @Test func `reasoningLevel maps to effort`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .deep
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        contextOptions: contextOptions
      ),
      configuration: .make()
    )
    #expect(request.reasoning?.effort == "high")
  }

  @Test func `custom reasoning level names an OpenRouter effort directly`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .custom("minimal")
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        contextOptions: contextOptions
      ),
      configuration: .make()
    )
    #expect(request.reasoning?.effort == "minimal")
  }

  @Test func `reasoning is omitted for models configured without it`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .deep
    let model = OpenRouterModel(id: "test/model", capabilities: .init(reasoning: false))
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        contextOptions: contextOptions
      ),
      configuration: .make(model: model)
    )
    #expect(request.reasoning == nil)
  }

  @Test func `budget reasoning policy sends max_tokens`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))])
      ),
      configuration: .make(reasoning: .budget(2048))
    )
    #expect(request.reasoning?.maxTokens == 2048)
    #expect(request.reasoning?.effort == nil)
  }

  @Test func `automatic caching marks system and last user message`() throws {
    let transcript = Transcript(entries: [
      .instructions(.init(segments: [.text(.init(content: "Be concise."))], toolDefinitions: [])),
      .prompt(.init(segments: [.text(.init(content: "First"))])),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "One."))])),
      .prompt(.init(segments: [.text(.init(content: "Second"))])),
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make(caching: .automatic)
    )
    #expect(request.messages[0].content == [.text("Be concise.", cacheControl: CacheControl())])
    // Only the LAST user message is marked; the earlier one stays plain.
    #expect(request.messages[1].content == [.text("First")])
    #expect(request.messages[3].content == [.text("Second", cacheControl: CacheControl())])
  }

  @Test func `sampling maps to temperature, top_p, top_k, and seed`() throws {
    var options = GenerationOptions()
    options.temperature = 0.7
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        generationOptions: options
      ),
      configuration: .make()
    )
    #expect(request.temperature == 0.7)

    var greedy = GenerationOptions()
    greedy.samplingMode = .greedy
    let greedyRequest = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        generationOptions: greedy
      ),
      configuration: .make()
    )
    #expect(greedyRequest.temperature == 0)
  }

  @Test func `tool choice maps required and disallowed modes`() throws {
    var required = GenerationOptions()
    required.toolCallingMode = .required
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        enabledTools: [
          .init(name: "t", description: "d", parameters: TestArgs.generationSchema)
        ],
        generationOptions: required
      ),
      configuration: .make()
    )
    #expect(request.toolChoice == .required)
  }

  @Test func `fallback models, transforms, and provider preferences flow through`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))])
      ),
      configuration: .make(
        provider: .init(
          order: ["anthropic"],
          dataCollection: .deny,
          sort: .throughput,
          zdr: true
        ),
        fallbackModels: ["openai/gpt-5-mini"],
        transforms: ["middle-out"]
      )
    )
    #expect(request.models == ["openai/gpt-5-mini"])
    #expect(request.transforms == ["middle-out"])
    #expect(request.provider?.order == ["anthropic"])
    #expect(request.provider?.dataCollection == "deny")
    #expect(request.provider?.sort == "throughput")
    #expect(request.provider?.zdr == true)
    // No schema in play — require_parameters stays unset.
    #expect(request.provider?.requireParameters == nil)
  }

  @Test func `server tools append after client tools and skip tool_choice`() throws {
    var required = GenerationOptions()
    required.toolCallingMode = .required
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        generationOptions: required
      ),
      configuration: .make(
        serverTools: [.webSearch(maxResults: 3, engine: .exa)]
      )
    )
    let tools = try #require(request.tools)
    #expect(tools.count == 1)
    guard case .serverTool(let type, let options) = tools[0] else {
      Issue.record("expected a server tool")
      return
    }
    #expect(type == "openrouter:web_search")
    #expect(options["max_results"] == .number(3))
    #expect(options["engine"] == .string("exa"))
    // tool_choice governs client function tools only; none exist here.
    #expect(request.toolChoice == nil)
  }

  @Test func `citation segments are not replayed as text`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "News?"))])),
      .response(
        .init(
          assetIDs: [],
          segments: [
            .text(.init(content: "Big news today.")),
            .custom(
              OpenRouterCitationSegment(
                id: "https://example.com",
                content: .init(url: "https://example.com", title: "Example")
              )
            ),
          ]
        )
      ),
      .prompt(.init(segments: [.text(.init(content: "More?"))])),
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make()
    )
    #expect(request.messages[1].content == [.text("Big news today.")])
  }

  @Test func `no provider preferences means no provider object`() throws {
    let request = try RequestBuilder.build(
      from: .make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))])
      ),
      configuration: .make()
    )
    #expect(request.provider == nil)
  }
}

@Generable
private struct TestArgs {
  var city: String
}

@Generable
private struct OptionalArgs {
  var city: String
  var nickname: String?
}

@Generable
private struct NestedArgs {
  @Guide(description: "The nested value")
  var inner: NestedInner
}

@Generable
private struct NestedInner {
  var value: String
}

@Generable
private struct BoundedArgs {
  @Guide(description: "d", .range(1...5))
  var days: Int
  @Guide(description: "t", .minimumCount(2))
  var tags: [String]
  @Guide(description: "c", /[a-z]+/)
  var code: String
}
