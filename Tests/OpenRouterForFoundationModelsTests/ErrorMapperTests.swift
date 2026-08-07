// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI
import Testing

@testable import OpenRouterForFoundationModels

@Suite struct ErrorMapperTests {
  @Test func `401 maps to invalidCredential`() {
    let mapped = ErrorMapper.map(APIError(code: 401, message: "Invalid key"))
    guard case OpenRouterError.invalidCredential(let message) = mapped else {
      Issue.record("expected invalidCredential, got \(mapped)")
      return
    }
    #expect(message == "Invalid key")
  }

  @Test func `402 maps to insufficientCredits`() {
    let mapped = ErrorMapper.map(APIError(code: 402, message: "Add credits"))
    guard case OpenRouterError.insufficientCredits = mapped else {
      Issue.record("expected insufficientCredits, got \(mapped)")
      return
    }
  }

  @Test func `403 with moderation metadata maps to guardrailViolation`() {
    let error = APIError(
      code: 403,
      message: "Flagged",
      metadata: .object([
        "reasons": .array([.string("violence")]),
        "flagged_input": .string("bad text…"),
        "provider_name": .string("SomeProvider"),
      ])
    )
    let mapped = ErrorMapper.map(error)
    guard case LanguageModelError.guardrailViolation(let details) = mapped else {
      Issue.record("expected guardrailViolation, got \(mapped)")
      return
    }
    #expect(details.debugDescription.contains("violence"))
    #expect(details.metadata["reasons"] as? [String] == ["violence"])
    #expect(details.metadata["provider"] as? String == "SomeProvider")
  }

  @Test func `403 without moderation metadata stays a plain api error`() {
    let mapped = ErrorMapper.map(APIError(code: 403, message: "Forbidden"))
    guard case OpenRouterError.api(let code, _) = mapped else {
      Issue.record("expected api, got \(mapped)")
      return
    }
    #expect(code == 403)
  }

  @Test func `408 and URLError timeouts map to the framework's timeout`() {
    #expect(ErrorMapper.map(APIError(code: 408, message: "Timed out")) is LanguageModelError)
    #expect(ErrorMapper.map(URLError(.timedOut)) is LanguageModelError)
  }

  @Test func `429 maps to rateLimited`() {
    #expect(ErrorMapper.map(APIError(code: 429, message: "Slow down")) is LanguageModelError)
  }

  @Test func `502 maps to providerFailure and 503 to noProviderAvailable`() {
    guard
      case OpenRouterError.providerFailure = ErrorMapper.map(
        APIError(code: 502, message: "Bad gateway")
      )
    else {
      Issue.record("expected providerFailure")
      return
    }
    guard
      case OpenRouterError.noProviderAvailable = ErrorMapper.map(
        APIError(code: 503, message: "No providers")
      )
    else {
      Issue.record("expected noProviderAvailable")
      return
    }
  }

  @Test func `400 context overflow maps to contextSizeExceeded`() {
    let mapped = ErrorMapper.map(
      APIError(code: 400, message: "This model's maximum context length is 8192 tokens")
    )
    guard case LanguageModelError.contextSizeExceeded = mapped else {
      Issue.record("expected contextSizeExceeded, got \(mapped)")
      return
    }
  }

  @Test func `unmapped codes surface as OpenRouterError.api`() {
    let mapped = ErrorMapper.map(APIError(code: 400, message: "Bad request"))
    guard case OpenRouterError.api(let code, _) = mapped else {
      Issue.record("expected api, got \(mapped)")
      return
    }
    #expect(code == 400)
  }

  @Test func `non-API errors pass through unchanged`() {
    struct Boom: Error {}
    #expect(ErrorMapper.map(Boom()) is Boom)
  }
}
