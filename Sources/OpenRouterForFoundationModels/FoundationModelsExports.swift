// SPDX-License-Identifier: Apache-2.0

// The one place the `ServerFoundationModels` trait is spelled. Every other
// file in the module — and every module that imports this one, including the
// tests and the example — sees the framework's types through this re-export
// and needs no import of its own.
//
// Re-exporting is deliberate, not just convenience: the bridge's public API
// is stated in the framework's vocabulary (`OpenRouterLanguageModel`
// conforms to `LanguageModel`, callers drive it with `LanguageModelSession`),
// so a consumer would otherwise have to write the matching import themselves
// and get it right for whichever trait configuration they built with.
#if ServerFoundationModels
@_exported import ServerFoundationModels
#else
@_exported import FoundationModels
#endif
