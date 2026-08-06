// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Errors surfaced by the OpenRouter provider that don't map onto a
/// `LanguageModelError` case. Pattern-match to drive product flows
/// (key entry, top-up prompts, routing fallbacks).
public enum OpenRouterError: LocalizedError, Sendable {
  /// No usable credential. Provide an API key via ``AuthMode/apiKey(_:)``,
  /// or, when using ``AuthMode/proxied(headers:)``, check that the proxy
  /// supplies authentication.
  case missingCredential
  /// OpenRouter rejected the credential (disabled or invalid API key,
  /// expired OAuth session).
  case invalidCredential(message: String)
  /// The account or key has run out of credits (HTTP 402). Top up, or raise
  /// the key's limit.
  case insufficientCredits(message: String)
  /// The input was flagged by moderation (HTTP 403). `reasons` lists why;
  /// `flaggedInput` is the offending excerpt; `provider` is the endpoint
  /// that flagged it.
  case moderated(reasons: [String], flaggedInput: String?, provider: String?)
  /// No provider matched the routing requirements (HTTP 503) — e.g.
  /// `require_parameters` plus a parameter no endpoint supports, or an
  /// over-restrictive provider filter.
  case noProviderAvailable(message: String)
  /// The chosen model's provider is down or returned an invalid response
  /// (HTTP 502). Often transient; consider fallback models.
  case providerFailure(message: String)
  /// Any other OpenRouter error, carrying the wire code and message.
  case api(code: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingCredential:
      "No OpenRouter credential. Provide an API key."
    case .invalidCredential(let message):
      "OpenRouter rejected the credential: \(message)"
    case .insufficientCredits(let message):
      "Insufficient OpenRouter credits: \(message)"
    case .moderated(let reasons, _, let provider):
      "Input flagged by moderation"
        + (provider.map { " (\($0))" } ?? "")
        + (reasons.isEmpty ? "" : ": \(reasons.joined(separator: ", "))")
    case .noProviderAvailable(let message):
      "No provider meets the routing requirements: \(message)"
    case .providerFailure(let message):
      "Model provider unavailable: \(message)"
    case .api(let code, let message):
      "OpenRouter error \(code): \(message)"
    }
  }
}
