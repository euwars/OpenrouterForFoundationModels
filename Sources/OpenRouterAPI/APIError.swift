// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Error envelope returned by OpenRouter, both in HTTP error bodies and as a
/// mid-stream SSE chunk: `{"error": {"code": 402, "message": "...", "metadata": {...}}}`.
///
/// The HTTP status matches `code` for pre-stream failures; once streaming has
/// begun the status stays 200 and the error arrives as an event.
package struct APIError: Error, Sendable, Hashable, Codable {
  /// OpenRouter's numeric error code (mirrors the HTTP status: 400, 401, 402,
  /// 403, 408, 429, 502, 503, …).
  package var code: Int
  package var message: String
  /// Provider- or moderation-specific detail. Shape varies by error.
  package var metadata: JSONValue?

  package init(code: Int, message: String, metadata: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey { case code, message, metadata }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // `code` is documented as a number, but be lenient: some upstream
    // providers relay string codes.
    if let number = try? c.decode(Int.self, forKey: .code) {
      code = number
    } else if let text = try? c.decode(String.self, forKey: .code), let number = Int(text) {
      code = number
    } else {
      code = 0
    }
    message = try c.decodeIfPresent(String.self, forKey: .message) ?? "Unknown error"
    metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
  }

  // MARK: - Moderation metadata

  /// Why the input was flagged, when this is a moderation error.
  package var moderationReasons: [String]? {
    guard case .array(let values)? = metadata?["reasons"] else { return nil }
    let reasons = values.compactMap(\.stringValue)
    return reasons.isEmpty ? nil : reasons
  }

  /// The flagged input excerpt, when this is a moderation error.
  package var flaggedInput: String? {
    metadata?["flagged_input"]?.stringValue
  }

  /// The upstream provider associated with the error, when reported.
  package var providerName: String? {
    metadata?["provider_name"]?.stringValue
  }
}

extension APIError: LocalizedError {
  package var errorDescription: String? {
    "OpenRouter error \(code): \(message)"
      + (providerName.map { " (provider: \($0))" } ?? "")
  }
}

/// Top-level error body: `{"error": {...}}`.
package struct APIErrorEnvelope: Decodable {
  package var error: APIError
}
