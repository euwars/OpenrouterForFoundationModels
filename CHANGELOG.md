# Changelog

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
