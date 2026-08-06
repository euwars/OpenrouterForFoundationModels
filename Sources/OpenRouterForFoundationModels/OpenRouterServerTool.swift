// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
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
/// often to invoke a server tool; results surface as
/// ``OpenRouterCitationSegment`` custom segments on the response.
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

/// A web-search citation attached to the response, surfaced as a custom
/// segment so apps can render grounded sources:
///
/// ```swift
/// for case .response(let response) in session.transcript {
///   for case .custom(let segment) in response.segments {
///     if let citation = segment as? OpenRouterCitationSegment {
///       print(citation.content.title ?? citation.content.url)
///     }
///   }
/// }
/// ```
public struct OpenRouterCitationSegment: Transcript.CustomSegment {
  public struct Content: Sendable, Codable, Equatable {
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

  public var id: String
  public var content: Content

  public init(id: String, content: Content) {
    self.id = id
    self.content = content
  }

  public var description: String {
    if let title = content.title, !title.isEmpty {
      "[\(title)](\(content.url))"
    } else {
      content.url
    }
  }

  public var promptRepresentation: Prompt { Prompt(description) }
  public var instructionsRepresentation: Instructions { Instructions(description) }
}
