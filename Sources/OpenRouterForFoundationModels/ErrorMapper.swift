// SPDX-License-Identifier: Apache-2.0

import Foundation
#if ServerFoundationModels
import ServerFoundationModels
#else
import FoundationModels
#endif
import OpenRouterAPI

/// Maps OpenRouter failures onto the framework's typed errors so app
/// developers can pattern-match on well-known cases; everything without an
/// honest framework equivalent surfaces as ``OpenRouterError``.
enum ErrorMapper {
  static func map(_ error: any Error) -> any Error {
    if let api = error as? APIError {
      return map(api)
    }
    if let url = error as? URLError, url.code == .timedOut {
      return LanguageModelError.timeout(.init(debugDescription: url.localizedDescription))
    }
    return error
  }

  static func map(_ error: APIError) -> any Error {
    switch error.code {
    case 401:
      return OpenRouterError.invalidCredential(message: error.message)
    case 402:
      return OpenRouterError.insufficientCredits(message: error.message)
    case 403:
      // Moderation flags map to the framework's guardrail error so safety
      // stops share one catch path with `content_filter` finishes. Other
      // 403s are permission errors — the credential exists but isn't
      // allowed here, so surface the raw error rather than sending users
      // to key entry.
      if let reasons = error.moderationReasons {
        var metadata: [String: any Sendable] = ["reasons": reasons]
        if let flagged = error.flaggedInput { metadata["flaggedInput"] = flagged }
        if let provider = error.providerName { metadata["provider"] = provider }
        return LanguageModelError.guardrailViolation(
          .init(
            debugDescription:
              "Input flagged by moderation: \(reasons.joined(separator: ", "))",
            metadata: metadata
          )
        )
      }
      return OpenRouterError.api(code: error.code, message: error.message)
    case 408:
      return LanguageModelError.timeout(.init(debugDescription: error.message))
    case 413:
      // OpenRouter reports neither the window nor the prompt's token count.
      return LanguageModelError.contextSizeExceeded(
        .init(contextSize: 0, tokenCount: 0, debugDescription: error.message)
      )
    case 429:
      // OpenRouter doesn't say when capacity returns, so no reset date is
      // fabricated — callers pick their own backoff.
      return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: error.message))
    case 502:
      return OpenRouterError.providerFailure(message: error.message)
    case 503:
      return OpenRouterError.noProviderAvailable(message: error.message)
    case 400 where isContextOverflow(error.message):
      return LanguageModelError.contextSizeExceeded(
        .init(contextSize: 0, tokenCount: 0, debugDescription: error.message)
      )
    default:
      return OpenRouterError.api(code: error.code, message: error.message)
    }
  }

  /// Providers word context overflows differently; match the common phrasings.
  private static func isContextOverflow(_ message: String) -> Bool {
    let lowered = message.lowercased()
    return lowered.contains("context length")
      || lowered.contains("context window")
      || lowered.contains("maximum context")
      || lowered.contains("too many tokens")
      || lowered.contains("exceeds the maximum")
  }
}
