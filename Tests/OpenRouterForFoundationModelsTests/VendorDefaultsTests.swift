// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import OpenRouterForFoundationModels

@Suite struct VendorDefaultsTests {
  @Test func `bare IDs resolve measured vendor defaults`() {
    // Verified vendors skip the guide-constraint probe.
    #expect(OpenRouterModel(id: "openai/gpt-5.6-luna").capabilities.guideConstraints == .included)
    // Anthropic's strict validator rejects bound keywords — measured live.
    #expect(
      OpenRouterModel(id: "anthropic/claude-opus-5").capabilities.guideConstraints == .stripped
    )

    // Measured limitations apply.
    #expect(OpenRouterModel(id: "amazon/nova-2-lite-v1").capabilities.structuredOutput == false)
    #expect(OpenRouterModel(id: "cohere/command-a").capabilities.reasoning == false)
    #expect(OpenRouterModel(id: "cohere/command-a").capabilities.toolCalling == false)
    #expect(OpenRouterModel(id: "meta-llama/llama-4-maverick").capabilities.reasoning == false)
  }

  @Test func `string literals resolve vendor defaults too`() {
    let model: OpenRouterModel = "google/gemini-3.6-flash"
    #expect(model.capabilities.guideConstraints == .included)
  }

  @Test func `unknown vendors get permissive defaults with the probe`() {
    let capabilities = OpenRouterModel(id: "somebody/new-model").capabilities
    #expect(capabilities.structuredOutput)
    #expect(capabilities.reasoning)
    #expect(capabilities.guideConstraints == .automatic)
  }

  @Test func `explicit capabilities always win over vendor defaults`() {
    let model = OpenRouterModel(
      id: "amazon/nova-2-lite-v1",
      capabilities: .init(structuredOutput: true)
    )
    #expect(model.capabilities.structuredOutput)
  }

  @Test func `framework capabilities reflect measured limitations`() {
    let model = OpenRouterLanguageModel(name: "cohere/command-a", auth: .apiKey("k"))
    #expect(!model.capabilities.contains(.reasoning))
    #expect(!model.capabilities.contains(.toolCalling))
    #expect(model.capabilities.contains(.guidedGeneration))
  }
}
