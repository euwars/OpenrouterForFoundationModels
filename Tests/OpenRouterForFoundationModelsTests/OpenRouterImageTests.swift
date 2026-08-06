// SPDX-License-Identifier: Apache-2.0

#if canImport(CoreGraphics) && canImport(ImageIO)

import CoreGraphics
import Foundation
#if ServerFoundationModels
import ServerFoundationModels
#else
import FoundationModels
#endif
import ImageIO
import Testing

@testable import OpenRouterForFoundationModels

/// A small solid-color image for exercising attachment paths.
func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage {
  let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()!
}

private func decodedSize(_ data: Data) -> (width: Int, height: Int)? {
  guard
    let source = CGImageSourceCreateWithData(data as CFData, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let width = properties[kCGImagePropertyPixelWidth] as? Int,
    let height = properties[kCGImagePropertyPixelHeight] as? Int
  else { return nil }
  return (width, height)
}

@Suite struct OpenRouterImageTests {
  @Test func `small images encode without resizing`() throws {
    let image = try OpenRouterImage(cgImage: makeTestImage(width: 40, height: 20))
    let size = try #require(decodedSize(image.data))
    #expect(size.width == 40)
    #expect(size.height == 20)
    #expect(image.dataURL.hasPrefix("data:image/jpeg;base64,"))
  }

  @Test func `oversized images downscale preserving aspect ratio`() throws {
    let image = try OpenRouterImage(cgImage: makeTestImage(width: 4000, height: 2000))
    let size = try #require(decodedSize(image.data))
    #expect(max(size.width, size.height) <= OpenRouterImage.maxLongEdge)
    #expect(size.width * size.height <= OpenRouterImage.maxPixelCount + 5000)
    let ratio = Double(size.width) / Double(size.height)
    #expect(abs(ratio - 2.0) < 0.05)
  }

  @Test func `target long edge respects both caps and never upscales`() {
    // Under every limit: unchanged.
    #expect(OpenRouterImage.targetLongEdge(width: 800, height: 600) == 800)
    // Long, skinny image: long-edge cap binds.
    #expect(OpenRouterImage.targetLongEdge(width: 4000, height: 100) == 1568)
    // Square image: area cap binds before the long edge.
    let square = OpenRouterImage.targetLongEdge(width: 1600, height: 1600)
    #expect(square < 1568)
    #expect(square * square <= OpenRouterImage.maxPixelCount + 5000)
  }

  @Test func `orientation bakes into the pixels`() throws {
    // A 40×20 capture tagged 90°-rotated must upload as 20×40.
    let image = try OpenRouterImage(
      cgImage: makeTestImage(width: 40, height: 20),
      orientation: .right
    )
    let size = try #require(decodedSize(image.data))
    #expect(size.width == 20)
    #expect(size.height == 40)
  }

  @Test func `image attachments become normalized image_url parts`() throws {
    let transcript = Transcript(entries: [
      .prompt(
        .init(segments: [
          .text(.init(content: "What is this?")),
          .attachment(.init(content: .image(.init(makeTestImage(width: 10, height: 10))))),
        ])
      )
    ])
    let request = try RequestBuilder.build(
      from: .make(transcript: transcript),
      configuration: .make()
    )
    let parts = request.messages[0].content
    #expect(parts.count == 2)
    guard case .imageURL(let url) = parts[1] else {
      Issue.record("expected an image part")
      return
    }
    #expect(url.hasPrefix("data:image/jpeg;base64,"))
  }
}

#endif
