// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(CoreImage)
import CoreImage
#endif

/// An image normalized for an OpenRouter `image_url` content part.
///
/// Providers behind OpenRouter resize oversized images before billing, which
/// costs latency the caller never sees — and the strictest ones reject them.
/// ``OpenRouterImage`` normalizes up front: it bakes in the capture
/// orientation so a portrait photo displays upright, downscales to fit
/// ``maxLongEdge`` and ``maxPixelCount``, and re-encodes as JPEG. Re-encoding
/// from decoded pixels writes no EXIF/GPS/IPTC metadata by construction, so
/// capture location and device identifiers never reach the wire.
struct OpenRouterImage: Sendable, Hashable {
  /// JPEG bytes within ``maxByteCount`` and the dimension caps.
  let data: Data

  /// Longest edge kept without resizing — the strictest common denominator
  /// across the major providers behind OpenRouter.
  static let maxLongEdge = 1568
  /// Total pixel budget kept without resizing. For square-ish images this is
  /// the tighter bound (~1.07×1.07k).
  static let maxPixelCount = 1_150_000
  /// Per-image byte ceiling.
  static let maxByteCount = 5 * 1024 * 1024

  enum Error: LocalizedError, Sendable {
    /// The image could not be drawn or re-encoded.
    case encodingFailed
    /// Still over ``maxByteCount`` after re-encoding at the lowest quality.
    case tooLarge(byteCount: Int)

    var errorDescription: String? {
      switch self {
      case .encodingFailed:
        "The image could not be encoded for upload."
      case .tooLarge(let byteCount):
        "The image is \(byteCount) bytes after compression, over the "
          + "\(OpenRouterImage.maxByteCount)-byte limit."
      }
    }
  }

  /// Encodes a decoded image (from a Foundation Models
  /// `Transcript.ImageAttachment`) to wire-ready JPEG: bakes in
  /// `orientation`, downscales to the dimension caps, re-encodes.
  init(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws {
    let upright = Self.baked(cgImage, orientation: orientation)
    let target = Self.targetLongEdge(width: upright.width, height: upright.height)
    let fitted =
      target < max(upright.width, upright.height)
      ? try Self.downscale(upright, toLongEdge: target)
      : upright
    self.data = try Self.encodeJPEG(fitted)
  }

  /// The wire-ready `image_url` value.
  var dataURL: String {
    "data:image/jpeg;base64,\(data.base64EncodedString())"
  }

  #if canImport(CoreImage)
  /// CIContext setup is expensive; one instance serves every image.
  private static let orientationContext = CIContext()
  #endif

  /// Rotates/flips the pixels so the image displays upright without an
  /// orientation tag — JPEG re-encoding below writes none. watchOS has no
  /// CoreImage; pixels pass through as captured there, which is upright for
  /// everything but rotated captures.
  private static func baked(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation
  ) -> CGImage {
    guard orientation != .up else { return image }
    #if canImport(CoreImage)
    let oriented = CIImage(cgImage: image).oriented(orientation)
    return Self.orientationContext.createCGImage(oriented, from: oriented.extent) ?? image
    #else
    return image
    #endif
  }

  /// Long-edge target, in pixels, that satisfies both ``maxLongEdge`` and
  /// ``maxPixelCount`` while preserving the aspect ratio. Never upscales.
  static func targetLongEdge(width: Int, height: Int) -> Int {
    let longEdge = max(width, height)
    let area = Double(width) * Double(height)
    let longEdgeScale = min(1, Double(Self.maxLongEdge) / Double(longEdge))
    let areaScale =
      area > Double(Self.maxPixelCount)
      ? (Double(Self.maxPixelCount) / area).squareRoot()
      : 1
    return max(1, Int((Double(longEdge) * min(longEdgeScale, areaScale)).rounded()))
  }

  private static func downscale(_ image: CGImage, toLongEdge target: Int) throws -> CGImage {
    let scale = Double(target) / Double(max(image.width, image.height))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw Error.encodingFailed
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let resized = context.makeImage() else { throw Error.encodingFailed }
    return resized
  }

  /// Steps quality down until the JPEG fits ``maxByteCount``. A ≤1.15 MP
  /// frame is well under the ceiling at the top quality; the lower steps
  /// guard pathological inputs.
  private static func encodeJPEG(_ image: CGImage) throws -> Data {
    var smallest: Data?
    for quality in [0.85, 0.6, 0.4, 0.25] {
      guard let encoded = encode(image, quality: quality) else {
        throw Error.encodingFailed
      }
      if encoded.count <= maxByteCount {
        return encoded
      }
      smallest = encoded
    }
    throw Error.tooLarge(byteCount: smallest?.count ?? .max)
  }

  private static func encode(_ image: CGImage, quality: Double) -> Data? {
    let out = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        out as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      return nil
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
  }
}
