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
  /// No provider matched the routing requirements (HTTP 503) — e.g.
  /// `require_parameters` plus a parameter no endpoint supports, or an
  /// over-restrictive provider filter.
  case noProviderAvailable(message: String)
  /// The chosen model's provider is down or returned an invalid response
  /// (HTTP 502). Often transient; consider fallback models.
  case providerFailure(message: String)
  /// Any other OpenRouter error, carrying the wire code and message.
  case api(code: Int, message: String)
  /// A decision model's response cannot answer a question as asked: an
  /// answer is missing, has another type, or names a choice option that
  /// was not offered. The message quotes the question's instructions.
  case unexpectedAnswer(message: String)
  /// A decision request was rejected before it was sent: an image that is
  /// not PNG, JPEG, or WebP, a choice with no options, or a score with no
  /// levels.
  case invalidDecisionRequest(message: String)

  public var errorDescription: String? {
    switch self {
    case .missingCredential:
      "No OpenRouter credential. Provide an API key."
    case .invalidCredential(let message):
      "OpenRouter rejected the credential: \(message)"
    case .insufficientCredits(let message):
      "Insufficient OpenRouter credits: \(message)"
    case .noProviderAvailable(let message):
      "No provider meets the routing requirements: \(message)"
    case .providerFailure(let message):
      "Model provider unavailable: \(message)"
    case .api(let code, let message):
      "OpenRouter error \(code): \(message)"
    case .unexpectedAnswer(let message):
      "Unexpected decision answer: \(message)"
    case .invalidDecisionRequest(let message):
      "Invalid decision request: \(message)"
    }
  }
}
