// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI

/// A tool that executes on OpenRouter's infrastructure within a single
/// round-trip. Configure per model with `serverTools:`:
///
/// ```swift
/// let model = OpenRouterLanguageModel(
///   name: "openai/gpt-5.2",
///   auth: auth,
///   serverTools: [.webSearch(maxResults: 5)]
/// )
/// ```
///
/// Distinct from the framework's `tools:` array, which holds client-side
/// tools the framework invokes on the device. The model decides when and how
/// often to invoke a server tool; results surface as ``OpenRouterCitation``
/// values in the response entry's metadata (``OpenRouterMetadata/citations``).
public struct OpenRouterServerTool: Sendable, Hashable {
  /// Which search backend serves `webSearch`. Omitting it lets OpenRouter
  /// pick (native provider search where available, Exa otherwise).
  public enum SearchEngine: String, Sendable, Hashable {
    case native, exa, parallel
  }

  enum Kind: Sendable, Hashable {
    case webSearch(maxResults: Int?, engine: SearchEngine?)
  }

  let kind: Kind

  /// Model-driven web search (`openrouter:web_search`).
  ///
  /// - Parameters:
  ///   - maxResults: Results per search (engine defaults apply when nil).
  ///   - engine: Search backend; nil lets OpenRouter choose.
  public static func webSearch(
    maxResults: Int? = nil,
    engine: SearchEngine? = nil
  ) -> OpenRouterServerTool {
    OpenRouterServerTool(kind: .webSearch(maxResults: maxResults, engine: engine))
  }

  /// The wire `tools`-array entry.
  var toolDefinition: ToolDefinition {
    switch kind {
    case .webSearch(let maxResults, let engine):
      var options: [String: JSONValue] = [:]
      if let maxResults { options["max_results"] = .number(Double(maxResults)) }
      if let engine { options["engine"] = .string(engine.rawValue) }
      return .serverTool(type: "openrouter:web_search", options: options)
    }
  }

  /// Stable ordering key so the wire request is deterministic — the prompt
  /// cache is a prefix match.
  var sortKey: String {
    switch kind {
    case .webSearch: "openrouter:web_search"
    }
  }
}

/// A web-search citation attached to a response. Citations live in the
/// response transcript entry's metadata under ``OpenRouterMetadata/citations``
/// (the Foundation Models SDK 27 release removed custom transcript segments,
/// which earlier bridge versions used); read them with
/// ``FoundationModels/Transcript/Response/openRouterCitations``:
///
/// ```swift
/// for case .response(let response) in session.transcript {
///   for citation in response.openRouterCitations {
///     print(citation.title ?? citation.url)
///   }
/// }
/// ```
public struct OpenRouterCitation: Sendable, Codable, Hashable {
  /// The cited page.
  public var url: String
  public var title: String?
  /// The excerpt the model grounded on.
  public var excerpt: String?
  /// Character range in the response text the citation covers, when the
  /// provider reports one.
  public var startIndex: Int?
  public var endIndex: Int?

  public init(
    url: String,
    title: String? = nil,
    excerpt: String? = nil,
    startIndex: Int? = nil,
    endIndex: Int? = nil
  ) {
    self.url = url
    self.title = title
    self.excerpt = excerpt
    self.startIndex = startIndex
    self.endIndex = endIndex
  }
}

extension OpenRouterCitation: ConvertibleToGeneratedContent, ConvertibleFromGeneratedContent {
  public var generatedContent: GeneratedContent {
    GeneratedContent(properties: [
      "url": url,
      "title": title,
      "excerpt": excerpt,
      "startIndex": startIndex,
      "endIndex": endIndex,
    ])
  }

  public init(_ content: GeneratedContent) throws {
    self.init(
      url: try content.value(String.self, forProperty: "url"),
      title: try content.value(String?.self, forProperty: "title"),
      excerpt: try content.value(String?.self, forProperty: "excerpt"),
      startIndex: try content.value(Int?.self, forProperty: "startIndex"),
      endIndex: try content.value(Int?.self, forProperty: "endIndex")
    )
  }
}

extension Transcript.Response {
  /// Web-search citations the model attached to this response, in the order
  /// the provider reported them (one per URL). Empty when there were none.
  public var openRouterCitations: [OpenRouterCitation] {
    guard let content = metadata[OpenRouterMetadata.citations] else { return [] }
    return (try? content.value([OpenRouterCitation].self)) ?? []
  }
}
