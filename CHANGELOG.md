# Changelog

## 0.5.1 (2026-10-28)

- Anthropic-family requests mark the system message's last text part with
  `cache_control`, at the same retention as the top-level automatic marker.
  Before, they carried only the top-level marker, which moves with the tail,
  so a request whose history differed from the previous one read none of the
  unchanged tools and instructions from cache; measured with
  anthropic/claude-sonnet-5.5, such a request read 0 of 11,181 prompt tokens
  from cache before and 9,940 after, and its first token came about 0.5 s
  sooner. An empty system message is left unmarked, as Anthropic refuses an
  empty marked block.

## 0.5.0 (2026-10-23)

The framework is chosen by platform. The bridge compiles against Apple's
FoundationModels on Apple platforms and against ServerFoundationModels on
Linux, with no trait required. The `ServerFoundationModels` trait remains as a
force override for Apple platforms (parity testing on a Mac, apps that import
`ServerFoundationModels` directly, cross-compilation).

- A consumer that previously enabled the trait only to build on Linux can drop
  it. A consumer whose app imports `ServerFoundationModels` directly on a Mac
  must keep it, or the bridge's types no longer match the app's.
- The `User-Agent` SDK version now tracks the package version (it had stayed at
  0.1.0).
- No source changes to the bridge's behavior. The same test suites pass under
  both frameworks on macOS and under ServerFoundationModels on Linux.

## 0.4.0 (2026-10-23)

Native support for OpenRouter's decision models (Perplexity Decider, TypeSafe
Jev, Cloudflare Clef, and the rest of the `output_modalities=decisions`
catalog).

- `OpenRouterDecisionModel` calls the Decisions endpoint (`alpha/decisions`)
  with the same `auth`, `provider`, `attribution`, `sessionID`, `baseURL`, and
  `timeout` options as `OpenRouterLanguageModel`. `decide(about:_:)` takes
  state and typed questions (`.noul`, `.choice`, `.score`, `.box`, `.all`) and
  returns each answer typed by its question, in the order asked. Decision
  models are not a `LanguageModel` and don't run in a `LanguageModelSession`.
- State images must be PNG, JPEG, or WebP. On Apple platforms they get the
  same normalization as chat attachments; on Linux they go out as given.
- **Breaking:** `OpenRouterError` gains `unexpectedAnswer(message:)` and
  `invalidDecisionRequest(message:)`. An exhaustive `switch` over
  `OpenRouterError` without a `default` no longer compiles until it handles
  them.
- HTTP failures from decision requests map to the same errors as chat
  (`OpenRouterError` for 401, 402, 502, and 503; `LanguageModelError` for 408,
  413, and 429).

## 0.3.0 (2026-09-11)

Xcode 27.0 GM alignment. The Foundation Models SDK 27 release removed custom
transcript segments and moved entry metadata to `GeneratedContent`; the bridge
now builds against the GM in both trait configurations.

- **Breaking:** web-search citations are no longer `OpenRouterCitationSegment`
  custom segments. They live on the response entry's metadata under
  `OpenRouterMetadata.citations` as `[OpenRouterCitation]`; read them with
  `Transcript.Response.openRouterCitations`. Same fields as before (URL,
  title, excerpt, character range), now also round-tripped by `Transcript`'s
  Codable encoding.
- Request metadata (`OpenRouterMetadata.user`, `.sessionID`) and response
  metadata (`.servedTier`, `.cost`) follow the SDK's `GeneratedContent`
  values; readers compare against `GeneratedContent("…")` or call `value(_:)`.
- Requires ServerFoundationModels 0.8.0 (the matching GM alignment) under the
  `ServerFoundationModels` trait.

## 0.2.0 (2026-08-07)

- The module now re-exports the Foundation Models surface it was built
  against. `import OpenRouterForFoundationModels` alone resolves
  `LanguageModelSession`, `@Generable`, and the rest, under either trait
  configuration — previously a consumer had to add the matching import
  themselves, and which one was correct depended on the trait they set.
  Existing code that imports the framework explicitly keeps working.
- Internally, the `ServerFoundationModels` trait is spelled once, in
  `FoundationModelsExports.swift`, instead of in every source, test, and
  example file. No behavior change to the trait or its conditional dependency.
- Fixed: the ServerFoundationModels dependency floor said `from: "0.6.0"`
  while the sources had already dropped the 0.6.0 compatibility shims in
  0.1.0. A consumer resolving 0.6.x would fail to build; the manifest now
  requires 0.7.0, matching what 0.1.0 documented.

## 0.1.0 (2026-08-07)

Initial release: OpenRouter as a Foundation Models server-side language model.

- Any OpenRouter model ID via `LanguageModelSession` — streaming, tool
  calling, guided generation, reasoning
- Strict `response_format: json_schema` with schema sanitization, the
  strict-mode rewrite, automatic `provider.require_parameters`, and
  optional client-side validation retries (`structuredOutputRetries`)
- `@Guide` bounds on the wire with a measured per-vendor fidelity table
  (`VendorDefaults`, seeded by `ModelConformanceTests`) and an automatic
  minimal-schema fallback for providers that reject constraint keywords
- Reasoning: effort/budget policies, framework hint mapping, and verbatim
  `reasoning_details` replay across tool turns
- `openrouter:web_search` server tool with `OpenRouterCitationSegment`
  citations
- Prompt caching: top-level automatic `cache_control` for Anthropic-family
  models, per-block breakpoints elsewhere; `session_id` sticky routing
- Service tiers (`flex`/`priority`/`fast`); served tier and generation cost
  surfaced on response transcript metadata
- Image normalization (orientation, downscale, metadata-free JPEG)
- Typed errors incl. moderation → `guardrailViolation`, `content_filter`
  and refusal finishes, and request correlators
- `ServerFoundationModels` package trait (requires 0.7.0): the same bridge
  compiles against euwars/ServerFoundationModels — Linux included,
  verified in CI on the `swift:6.2` container
