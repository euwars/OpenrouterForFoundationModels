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
- [Prompt caching](#prompt-caching)
- [Provider routing and fallbacks](#provider-routing-and-fallbacks)
- [App attribution](#app-attribution)
- [Error handling](#error-handling)
- [What this package provides](#what-this-package-provides)
- [License](#license)

## Requirements

- iOS 27, macOS 27, visionOS 27, or watchOS 27 (beta) — the OS releases whose Foundation Models framework supports server-side language models.
- Xcode 27 (beta).
- An [OpenRouter API key](https://openrouter.ai/settings/keys).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/<you>/OpenrouterForFoundationModels.git", from: "0.1.0")
]
```

Then add `OpenRouterForFoundationModels` to your target's dependencies and import it alongside `FoundationModels`:

```swift
import FoundationModels
import OpenRouterForFoundationModels
```

## Quick start

```swift
import FoundationModels
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

Any OpenRouter model ID works as a string literal — `"openai/gpt-5.2"`, `"google/gemini-3-pro"`, `"deepseek/deepseek-v4"`, including variant suffixes like `:nitro` and `:floor`. OpenRouter drops request parameters an endpoint doesn't support, so the default capabilities are permissive.

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

## Prompt caching

Providers that cache automatically (OpenAI, DeepSeek, Groq, …) need nothing. Anthropic and Gemini require explicit `cache_control` breakpoints; by default the bridge marks the system message and the final user message each turn, so a growing conversation re-reads its prefix from cache. Providers that don't use breakpoints ignore them.

```swift
OpenRouterLanguageModel(name: model, auth: auth, caching: .automatic)  // default, ~5 min TTL
OpenRouterLanguageModel(name: model, auth: auth, caching: .extended)   // 1-hour TTL
OpenRouterLanguageModel(name: model, auth: auth, caching: .disabled)
```

Cache hits are reported through the session's usage (`usage.input.cachedTokenCount`).

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
} catch OpenRouterError.moderated(let reasons, _, _) {
  // Input was flagged; adjust and retry.
} catch let error as LanguageModelError {
  // Guardrails, rate limits, context length, decoding.
}
```

Mid-stream provider failures (which arrive over HTTP 200) also fail the turn with a typed error.

## What this package provides

The public surface is Apple's Foundation Models provider conformance plus the configuration types that reach it — `OpenRouterLanguageModel`, `OpenRouterModel`, `AuthMode`, `ReasoningPolicy`, `ProviderPreferences`, `Attribution`, `CachePolicy`, and `OpenRouterError`. It is not a general-purpose OpenRouter API client.

## License

Apache 2.0.
