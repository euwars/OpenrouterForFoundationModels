// SPDX-License-Identifier: Apache-2.0

import Foundation

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
