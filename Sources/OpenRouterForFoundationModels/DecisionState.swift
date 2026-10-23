// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI

/// What a decision model judges: text, your own `Encodable` value, images,
/// or a list of those.
///
/// ```swift
/// about: "My checkout page shows a blank screen after I click Pay."
/// about: .json(ticket)
/// about: ["Listing title: Red square sticker", .image(photoData)]
/// about: .parts(["Compare these photos:"] + photos.map { .image($0) })
/// ```
///
/// Images always reach the wire as items of the top-level `state` array,
/// the one place every image-capable decision model reads them. A single
/// `.image` is sent as a one-item array; nested lists are flattened.
public struct DecisionState: Sendable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
  enum Content: Sendable {
    case text(String)
    case json(any Encodable & Sendable)
    case image(Data)
    case parts([DecisionState])
  }

  let content: Content

  /// Plain text.
  public static func text(_ text: String) -> DecisionState {
    DecisionState(content: .text(text))
  }

  /// Your value as JSON: an object for a struct, an array for a
  /// collection. Encoded with `JSONEncoder` using your coding keys and
  /// ISO 8601 dates, so a model reads `2026-10-23T17:51:00Z` rather than
  /// seconds since 2001. An encoding failure throws from `decide`.
  ///
  /// Images inside the value are not read as images; put them in a list
  /// beside it: `[.json(listing), .image(photo)]`.
  public static func json(_ value: some Encodable & Sendable) -> DecisionState {
    DecisionState(content: .json(value))
  }

  /// An encoded image: PNG, JPEG, or WebP bytes. Anything else, GIF
  /// included, throws ``OpenRouterError/invalidDecisionRequest(message:)``
  /// from `decide` before any request is sent.
  ///
  /// On Apple platforms the image is decoded, turned upright from its EXIF
  /// orientation, downscaled to at most 1568 px on the long edge and
  /// 1.15 MP, and re-encoded as metadata-free JPEG, the same normalization
  /// chat attachments get. Box answers are fractions of that upright
  /// image. Bytes ImageIO cannot decode are sent as they are.
  ///
  /// On Linux there is no image decoder: the bytes are sent as they are.
  /// Rotate photos before encoding them; Jev ignores EXIF orientation.
  public static func image(_ data: Data) -> DecisionState {
    DecisionState(content: .image(data))
  }

  /// A list built at runtime. The same as an array literal.
  public static func parts(_ parts: [DecisionState]) -> DecisionState {
    DecisionState(content: .parts(parts))
  }

  public init(stringLiteral value: String) {
    self.content = .text(value)
  }

  public init(arrayLiteral elements: DecisionState...) {
    self.content = .parts(elements)
  }

  init(content: Content) {
    self.content = content
  }

  /// The wire `state`: a string for `.text`, the encoded value for
  /// `.json`, and otherwise one flat array in which text items are plain
  /// strings (not `{"type":"text"}` parts), images are `image_url` parts,
  /// and nested lists are spliced in place.
  func wireValue() throws -> JSONValue {
    switch content {
    case .text(let text): .string(text)
    case .json(let value): try Self.encoded(value)
    case .image, .parts: .array(try items())
    }
  }

  private func items() throws -> [JSONValue] {
    switch content {
    case .text(let text): [.string(text)]
    case .json(let value): [try Self.encoded(value)]
    case .image(let data): [try Self.imagePart(data)]
    case .parts(let parts): try parts.flatMap { try $0.items() }
    }
  }

  private static func encoded(_ value: any Encodable) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
  }

  private static let acceptedMediaTypes: Set = ["image/png", "image/jpeg", "image/webp"]

  /// `{"type":"image_url","image_url":{"url":"data:<type>;base64,…"}}`.
  private static func imagePart(_ data: Data) throws -> JSONValue {
    let mediaType = RequestBuilder.sniffedMediaType(of: data)
    guard let mediaType, acceptedMediaTypes.contains(mediaType) else {
      throw OpenRouterError.invalidDecisionRequest(
        message: "Decision models accept PNG, JPEG, or WebP images; got "
          + (mediaType ?? "unrecognized bytes") + "."
      )
    }
    #if canImport(CoreGraphics) && canImport(ImageIO)
    if let normalized = try? OpenRouterImage(encoded: data) {
      return ["type": "image_url", "image_url": ["url": .string(normalized.dataURL)]]
    }
    #endif
    let url = "data:\(mediaType);base64,\(data.base64EncodedString())"
    return ["type": "image_url", "image_url": ["url": .string(url)]]
  }
}
