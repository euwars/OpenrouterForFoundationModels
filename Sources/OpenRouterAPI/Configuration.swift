// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct Configuration: Sendable {
  package enum Auth: Sendable, Hashable {
    case bearer(String)
    /// No credential. Use when the caller injects auth per-request headers,
    /// or when `baseURL` is a proxy that adds authentication server-side.
    case none
  }

  package var auth: Auth
  package var baseURL: URL

  package init(
    auth: Auth,
    baseURL: URL = URL(string: "https://openrouter.ai/api")!
  ) {
    self.auth = auth
    self.baseURL = baseURL
  }
}
