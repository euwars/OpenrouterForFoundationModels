// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI

/// Identifies the credential the executor uses. `Hashable` so the framework
/// can cache one executor per unique `(model, auth)` pair.
public enum AuthMode: Hashable, Sendable {
  /// OpenRouter API key, sent as `Authorization: Bearer`. Bundled keys are
  /// extractable from a shipping app; for production, use
  /// ``proxied(headers:)`` behind your own relay.
  case apiKey(String)
  /// Route requests through a developer-run proxy that adds the real
  /// credential server-side. `baseURL` points at the proxy; `headers` are
  /// sent on every request so the proxy can authorize the caller (e.g. a
  /// per-app secret or tenant ID). Pass `[:]` when the proxy needs no
  /// client-supplied headers.
  case proxied(headers: [String: String])
}

// The one owner of how a credential reaches the wire. The chat executor and
// the decision model both read it, so they cannot drift on, say, whether an
// empty key is an error.
extension AuthMode {
  /// The credential the client attaches to every request. An empty API key
  /// and `.proxied` both send no `Authorization` header.
  var clientAuth: OpenRouterAPI.Configuration.Auth {
    switch self {
    case .apiKey(let key) where !key.isEmpty: .bearer(key)
    case .apiKey, .proxied: .none
    }
  }

  /// Headers merged over the client's defaults: proxy authorization under
  /// `.proxied`, plus app attribution. Throws
  /// ``OpenRouterError/missingCredential`` for an empty API key, before any
  /// network call.
  func requestHeaders(attribution: Attribution?) throws -> [String: String] {
    var headers: [String: String] = [:]
    switch self {
    case .apiKey(let key):
      guard !key.isEmpty else { throw OpenRouterError.missingCredential }
    case .proxied(let proxyHeaders):
      headers.merge(proxyHeaders) { _, proxy in proxy }
    }
    if let attribution {
      if let url = attribution.siteURL {
        headers["HTTP-Referer"] = url.absoluteString
      }
      if let name = attribution.appName {
        headers["X-Title"] = name
      }
    }
    return headers
  }
}
