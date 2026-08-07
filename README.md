# OpenRouter for Foundation Models

Use any [OpenRouter](https://openrouter.ai) model as a server-side language model through Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework. The package conforms OpenRouter to the framework's `LanguageModel` protocol, so you drive it with the same `LanguageModelSession` API you use for Apple's on-device model — `respond(to:)`, streaming, guided generation, tool calling, and reasoning all work the same way, against hundreds of models behind one key.

> **Beta.** This package targets the Foundation Models server-side language model API introduced in the OS 27 betas. APIs may change before general availability.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Example](#example)
- [Choosing a model](#choosing-a-model)
- [Authentication](#authentication)
- [Streaming](#streaming)
- [Structured output](#structured-output)
- [Reasoning](#reasoning)
- [Server-side web search](#server-side-web-search)
- [Prompt caching](#prompt-caching)
- [Service tiers](#service-tiers)
- [Provider routing and fallbacks](#provider-routing-and-fallbacks)
- [App attribution](#app-attribution)
- [Error handling](#error-handling)
- [What this package provides](#what-this-package-provides)
- [License](#license)

## Requirements

- iOS 27, macOS 27, visionOS 27, or watchOS 27 (beta) — the OS releases whose Foundation Models framework supports server-side language models.
- Xcode 27 (beta).
- An [OpenRouter API key](https://openrouter.ai/settings/keys).

### Using ServerFoundationModels instead of Apple's framework

The bridge also compiles against [ServerFoundationModels](https://github.com/euwars/ServerFoundationModels), the open-source reimplementation of the FoundationModels surface, via a package trait — same `OpenRouterLanguageModel`, same sessions and `@Generable` macros:

```swift
.package(
  url: "https://github.com/euwars/OpenrouterForFoundationModels.git",
  from: "0.1.0",
  traits: ["ServerFoundationModels"]
)
```

The trait is off by default (Apple's framework, exactly as documented below). The full test suite passes under both backends, including on Linux (`swift:6.2` container — verified in CI on every push).

Linux notes: images attach as raw bytes and inline with a sniffed media type (no CoreGraphics normalization), retry logs go to stderr instead of `os.Logger`, and SSE responses arrive whole rather than incrementally — corelibs-foundation's `URLSession` has no byte-streaming API, so partial snapshots deliver at once when the response completes.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/euwars/OpenrouterForFoundationModels.git", from: "0.1.0")
]
```

Then add `OpenRouterForFoundationModels` to your target's dependencies and import it. The module re-exports whichever Foundation Models surface it was built against, so one import brings in `LanguageModelSession`, `@Generable`, and the rest — under either trait configuration:

```swift
import OpenRouterForFoundationModels
```

## Quick start

```swift
import OpenRouterForFoundationModels

let model = OpenRouterLanguageModel(
  name: "anthropic/claude-sonnet-4.5",
  auth: .apiKey(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "")
)

let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Plan a 4-day trip to Buenos Aires.")
print(response.content)
```

`OpenRouterLanguageModel` is the entry point. Pass it to `LanguageModelSession` and use the session exactly as you would with any Foundation Models provider.

## Example

[`Examples/OpenRouterExample`](Examples/OpenRouterExample) is a runnable command-line target that generates a structured `TripPlan` — a `@Generable` graph with an enum, nested structs, and `@Guide` constraints — through `LanguageModelSession` (running it requires a macOS 27 host):

```sh
OPENROUTER_API_KEY=<key> swift run OpenRouterExample "a long weekend in Kyoto"
```

Pass `--model` to run the same code against any OpenRouter model, and `--reasoning` to pin an effort level:

```sh
OPENROUTER_API_KEY=<key> swift run OpenRouterExample \
  --model anthropic/claude-sonnet-4.5 --reasoning high "two weeks in Patagonia"
```

## Choosing a model

Any OpenRouter model ID works as a string literal — `"openai/gpt-5.2"`, `"google/gemini-3-pro"`, `"deepseek/deepseek-v4"`, including variant suffixes like `:nitro` and `:floor`. Bare IDs resolve **measured per-vendor defaults** (`VendorDefaults.swift`, seeded by running `ModelConformanceTests` against each top vendor's most-used model) — e.g. `amazon/*` models don't accept `response_format` on OpenRouter, so guided generation fails fast client-side; `cohere/*` gets no reasoning or tool routing. Unknown vendors get permissive defaults, since OpenRouter drops parameters an endpoint doesn't support.

Override capabilities when the framework shouldn't route certain work to the model at all:

```swift
let model = OpenRouterModel(
  id: "some/older-model",
  capabilities: .init(reasoning: false, structuredOutput: false)
)
OpenRouterLanguageModel(name: model, auth: auth)
```

- `toolCalling` — client-side tools (`tools` / `tool_calls`)
- `imageInput` — image parts on user messages
- `reasoning` — the `reasoning` parameter and streamed reasoning tokens
- `structuredOutput` — `response_format: json_schema` guided generation

## Authentication

```swift
// Development. A bundled key is extractable from a shipping app,
// so don't release with one.
OpenRouterLanguageModel(name: "openai/gpt-5-mini", auth: .apiKey("sk-or-..."))

// Production. The relay at `baseURL` adds the OpenRouter key server-side;
// the app ships no key. `headers` are sent on every request so the proxy
// can authorize the caller — pass `[:]` if it needs none.
OpenRouterLanguageModel(
  name: "openai/gpt-5-mini",
  auth: .proxied(headers: ["X-App-Token": "..."]),
  baseURL: URL(string: "https://api.yourapp.com/openrouter")!
)
```

The proxy sees the standard OpenRouter wire format — point `baseURL` at anything that forwards to `https://openrouter.ai/api/v1/chat/completions`.

## Streaming

`streamResponse(to:)` returns the response incrementally. Each element is a cumulative snapshot:

```swift
let stream = session.streamResponse(to: "Summarize today's top science stories.")
for try await partial in stream {
  print(partial.content)
}
```

## Structured output

Annotate a type with `@Generable` and request it with `generating:`. The bridge sends the schema as strict `response_format: json_schema` and automatically sets `provider.require_parameters` so routing only considers endpoints that enforce it:

```swift
@Generable
struct Trip {
  @Guide(description: "Destination city") var destination: String
  @Guide(description: "Length in days", .range(1...14)) var days: Int
}

let response = try await session.respond(to: "Plan a trip to Tokyo.", generating: Trip.self)
print(response.content.destination)
```

The framework's schema is sanitized for strict validators (extension keys stripped, `additionalProperties: false` everywhere) and rewritten to the strict-mode shape: every property required, previously optional properties made nullable.

`@Guide` constraints (`.range`, `.count`, `.minimumCount`, regex patterns) go on the wire as their JSON Schema keywords (`minimum`, `minItems`, `pattern`, …) so providers that support them enforce the bounds during generation. If a provider's validator rejects those keywords, the bridge retries once without them and remembers that model for the rest of the process. The probe is cheap — a rejected schema fails validation before generation, so it bills no tokens and costs one round trip, at most once per model per launch.

Pin the behavior to skip probing entirely when the model is known:

```swift
// Always send constraints; a provider that rejects them surfaces the error.
OpenRouterModel(id: "openai/gpt-5.2", capabilities: .init(guideConstraints: .included))

// Never send constraints; bounds are prompt guidance only.
OpenRouterModel(id: "some/legacy-model", capabilities: .init(guideConstraints: .stripped))
```

If routing finds no structured-output endpoint for the model, the request fails with ``OpenRouterError/noProviderAvailable(message:)`` rather than silently returning unvalidated JSON.

## Reasoning

The framework's per-request reasoning hints map to OpenRouter's unified `reasoning` parameter (`.light` → `low`, `.moderate` → `medium`, `.deep` → `high`); OpenRouter converts effort to token budgets for budget-based models. Pin a policy for every request with `reasoning:` — it wins over the hints and reaches levels they can't express:

```swift
// Effort-based (OpenAI, Grok, …)
OpenRouterLanguageModel(name: "openai/gpt-5.2", auth: auth, reasoning: .effort(.xhigh))

// Budget-based (Anthropic, Gemini, …)
OpenRouterLanguageModel(name: "anthropic/claude-sonnet-4.5", auth: auth, reasoning: .budget(8000))

// Reason internally but don't stream the thoughts back
OpenRouterLanguageModel(name: "openai/gpt-5.2", auth: auth, reasoning: .effort(.high, exclude: true))
```

Streamed reasoning surfaces as the session's reasoning entries. OpenRouter's `reasoning_details` blocks (signed, summarized, or encrypted thoughts) are preserved on the transcript and replayed verbatim on later turns — required to keep the thought chain valid across tool-use turns on models that sign their reasoning.

### Retrying unreliable providers

Some endpoints occasionally return JSON that violates the schema. `structuredOutputRetries` re-requests such turns transparently (default 0 — off). Attempts buffer until one validates, and every retry is logged via `os.Logger` (subsystem `OpenRouterForFoundationModels`):

```swift
OpenRouterLanguageModel(name: model, auth: auth, structuredOutputRetries: 2)
```

## Server-side web search

`openrouter:web_search` runs on OpenRouter's infrastructure within the request — the model decides when to search:

```swift
let model = OpenRouterLanguageModel(
  name: "openai/gpt-5.2",
  auth: auth,
  serverTools: [.webSearch(maxResults: 5)]
)
```

Citations surface on the transcript as ``OpenRouterCitationSegment`` custom segments (URL, title, excerpt), ready for grounded-source UI:

```swift
for case .response(let response) in session.transcript {
  for case .custom(let segment) in response.segments {
    if let citation = segment as? OpenRouterCitationSegment {
      print(citation.content.title ?? citation.content.url)
    }
  }
}
```

## Prompt caching

Providers that cache automatically (OpenAI, DeepSeek, Groq, …) need nothing. For providers that want explicit markers, the bridge applies the right mechanism per model family: Anthropic models get top-level automatic `cache_control` (the breakpoint advances with the conversation), while Gemini, Qwen, and other breakpoint providers get `cache_control` markers on the system message and the final user message. Either way a growing conversation re-reads its prefix from cache.

```swift
OpenRouterLanguageModel(name: model, auth: auth, caching: .automatic)  // default, ~5 min TTL
OpenRouterLanguageModel(name: model, auth: auth, caching: .extended)   // 1-hour TTL
OpenRouterLanguageModel(name: model, auth: auth, caching: .disabled)
```

Cache hits are reported through the session's usage (`usage.input.cachedTokenCount`).

For multi-turn agent workflows, pin OpenRouter's sticky provider routing (which keeps caches warm across requests) with a session ID — per model, or per request via metadata:

```swift
OpenRouterLanguageModel(name: model, auth: auth, sessionID: "agent-session-123")
// or per request: request.metadata[OpenRouterMetadata.sessionID] = "agent-session-123"
```

## Service tiers

Trade cost against latency on providers that offer tiers (OpenAI, Google, xAI):

```swift
OpenRouterLanguageModel(name: "openai/gpt-5.2", auth: auth, serviceTier: .flex)     // ~50% cheaper, slower
OpenRouterLanguageModel(name: "openai/gpt-5.2", auth: auth, serviceTier: .priority) // faster, costlier
```

Billing follows the tier that actually served the request. The served tier and the generation's cost arrive on each response's transcript entry:

```swift
for case .response(let response) in session.transcript {
  let tier = response.metadata[OpenRouterMetadata.servedTier] as? String
  let cost = response.metadata[OpenRouterMetadata.cost] as? Double
}
```

## Provider routing and fallbacks

Control which upstream endpoints serve the request:

```swift
OpenRouterLanguageModel(
  name: "meta-llama/llama-4-maverick",
  auth: auth,
  provider: ProviderPreferences(
    order: ["groq", "fireworks"],
    dataCollection: .deny,
    sort: .throughput,
    zdr: true
  ),
  fallbackModels: ["openai/gpt-5-mini"]  // tried when the primary is down
)
```

## App attribution

Identify the app on OpenRouter rankings and analytics (`HTTP-Referer` / `X-Title`):

```swift
OpenRouterLanguageModel(
  name: model,
  auth: auth,
  attribution: Attribution(siteURL: URL(string: "https://yourapp.example"), appName: "YourApp")
)
```

## Error handling

Failures with a framework equivalent surface as `LanguageModelError` (`rateLimited`, `timeout`, `contextSizeExceeded`, …). OpenRouter-specific failures surface as `OpenRouterError`:

```swift
do {
  let response = try await session.respond(to: prompt)
  print(response.content)
} catch OpenRouterError.insufficientCredits {
  // Send the user to top up.
} catch LanguageModelError.guardrailViolation(let details) {
  // Input flagged by moderation or a provider content filter;
  // details.metadata carries the reasons when OpenRouter reports them.
} catch let error as LanguageModelError {
  // Rate limits, context length, timeouts, decoding.
}
```

Mid-stream provider failures (which arrive over HTTP 200) also fail the turn with a typed error.

## What this package provides

The public surface is Apple's Foundation Models provider conformance plus the configuration types that reach it — `OpenRouterLanguageModel`, `OpenRouterModel`, `AuthMode`, `ReasoningPolicy`, `ProviderPreferences`, `OpenRouterServerTool`, `OpenRouterCitationSegment`, `Attribution`, `CachePolicy`, `ServiceTier`, `OpenRouterMetadata`, and `OpenRouterError` — plus per-model knobs like `structuredOutputRetries` and `sessionID`. It is not a general-purpose OpenRouter API client.

## License

Apache 2.0.
