// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import GoogleMaps
import UIKit

/// Reproduces a polyline `strokePattern` (dash / dot / gap sequence) on iOS,
/// where the Google Maps SDK has no `pattern` API like Android.
///
/// A dotted/dashed line is drawn with `GMSStrokeStyle.stampStyle`. The SDK
/// compresses the stamp image into a **square** sized to the polyline stroke
/// width and tiles it edge-to-edge, top-of-image towards the start point. To
/// obtain a gap, the whole pattern period (dot + gap) is drawn into one square
/// tile and the polyline stroke width is set to that period, so the visible
/// dot/dash keeps its intended thickness while the transparent remainder forms
/// the gap.
enum PolylineStrokePatternTexture {
  struct Result {
    /// Span covering the whole polyline (see `GMSPolyline.spans`: the final
    /// span extends over the remaining length).
    let span: GMSStyleSpan
    /// Stroke width the polyline must use for the tile geometry to be 1:1 —
    /// equal to the pattern period, not the pattern's line thickness.
    let strokeWidth: CGFloat
  }

  /// Builds the stamp span for `pattern`, or returns `nil` when the pattern is
  /// empty / unrenderable (caller falls back to a solid stroke).
  ///
  /// - Parameter lineWidth: the intended visual thickness of dots/dashes
  ///   (the `strokeWidth` the Dart side requested).
  static func makeResult(
    pattern: [PatternItemDto],
    color: UIColor,
    lineWidth: CGFloat
  ) -> Result? {
    guard !pattern.isEmpty, lineWidth > 0 else { return nil }

    let period = pattern.reduce(CGFloat(0)) { acc, item in
      acc + segmentLength(for: item, lineWidth: lineWidth)
    }
    guard period > 0, period.isFinite else { return nil }

    let image = renderTile(pattern: pattern, color: color, lineWidth: lineWidth, period: period)
    let style = GMSStrokeStyle.solidColor(.clear)
    style.stampStyle = GMSTextureStyle(image: image)
    return Result(span: GMSStyleSpan(style: style), strokeWidth: period)
  }

  /// Draws one pattern period into a `period × period` square. The along-line
  /// axis is the image's vertical axis; the dot/dash keeps thickness
  /// `lineWidth` and is centred horizontally.
  ///
  /// The tile is built as a **straight-alpha** image whose RGB is the fill
  /// colour on every pixel — even fully transparent ones — and whose alpha
  /// channel carries the anti-aliased shape coverage. This avoids the dark rim
  /// that appears when a coloured shape sits on transparent-black pixels and the
  /// GPU blends the two while sampling the stamp texture: with a constant RGB
  /// there is no colour to bleed at the edges, only the alpha ramps down.
  private static func renderTile(
    pattern: [PatternItemDto],
    color: UIColor,
    lineWidth: CGFloat,
    period: CGFloat
  ) -> UIImage {
    let scale = UIScreen.main.scale
    let side = max(Int((period * scale).rounded()), 1)
    let pixelCount = side * side

    guard let coverage = renderCoverage(
      pattern: pattern, lineWidth: lineWidth, side: side, scale: scale
    ) else {
      return renderCoverageFallback(pattern: pattern, color: color, lineWidth: lineWidth, period: period)
    }

    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let r = UInt8((red * 255).rounded())
    let g = UInt8((green * 255).rounded())
    let b = UInt8((blue * 255).rounded())

    var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
    for i in 0..<pixelCount {
      rgba[i * 4] = r
      rgba[i * 4 + 1] = g
      rgba[i * 4 + 2] = b
      rgba[i * 4 + 3] = UInt8((CGFloat(coverage[i]) * alpha).rounded())
    }

    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
      let cgImage = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
      )
    else {
      return renderCoverageFallback(pattern: pattern, color: color, lineWidth: lineWidth, period: period)
    }
    return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
  }

  /// Renders the shape coverage (anti-aliased alpha, 0...255 per pixel) of one
  /// pattern period into a square alpha-only buffer.
  private static func renderCoverage(
    pattern: [PatternItemDto],
    lineWidth: CGFloat,
    side: Int,
    scale: CGFloat
  ) -> [UInt8]? {
    guard let context = CGContext(
      data: nil, width: side, height: side,
      bitsPerComponent: 8, bytesPerRow: side,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
    ) else {
      return nil
    }
    context.setShouldAntialias(true)
    context.setFillColor(gray: 1, alpha: 1)

    let originX = (CGFloat(side) - lineWidth * scale) / 2
    let width = lineWidth * scale
    var y: CGFloat = 0
    for item in pattern {
      let length = segmentLength(for: item, lineWidth: lineWidth) * scale
      switch item.type {
      case .dot:
        context.fillEllipse(in: CGRect(x: originX, y: y, width: width, height: width))
      case .dash:
        let rect = CGRect(x: originX, y: y, width: width, height: length)
        context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: width / 2).cgPath)
        context.fillPath()
      case .gap:
        break
      }
      y += length
    }

    guard let data = context.data else { return nil }
    let pointer = data.bindMemory(to: UInt8.self, capacity: side * side)
    return Array(UnsafeBufferPointer(start: pointer, count: side * side))
  }

  /// Simple fallback if the raw-buffer path is unavailable; may show a faint rim.
  private static func renderCoverageFallback(
    pattern: [PatternItemDto],
    color: UIColor,
    lineWidth: CGFloat,
    period: CGFloat
  ) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: period, height: period), format: format)
    return renderer.image { context in
      let cg = context.cgContext
      cg.setFillColor(color.cgColor)
      let originX = (period - lineWidth) / 2
      var y: CGFloat = 0
      for item in pattern {
        let length = segmentLength(for: item, lineWidth: lineWidth)
        switch item.type {
        case .dot:
          cg.fillEllipse(in: CGRect(x: originX, y: y, width: lineWidth, height: lineWidth))
        case .dash:
          let rect = CGRect(x: originX, y: y, width: lineWidth, height: length)
          cg.addPath(UIBezierPath(roundedRect: rect, cornerRadius: lineWidth / 2).cgPath)
          cg.fillPath()
        case .gap:
          break
        }
        y += length
      }
    }
  }

  /// Length consumed along the line by one pattern item, in points. A dot is a
  /// filled circle whose diameter equals the line width.
  private static func segmentLength(for item: PatternItemDto, lineWidth: CGFloat) -> CGFloat {
    switch item.type {
    case .dot:
      return lineWidth
    case .dash, .gap:
      return CGFloat(item.length ?? 0)
    }
  }
}
