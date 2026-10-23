//
//  MP fork patch 7: persistent text highlights (chat transcript annotations).
//

import CoreGraphics
import Foundation

/// How a highlight is painted.
/// - `background`: legacy `.backgroundColor` attribute on the text (find matches, flash words).
/// - `fill` / `underline` / `pen`: drawn on a layer *under* the text, so several strokes
///   on the same text stack (fills blend, underlines step down, pen = hand-drawn marker).
public enum TextHighlightStyle: String, Hashable, Sendable {
  case background, fill, underline, pen
}

/// A highlight run painted over every occurrence of `quote` in the rendered
/// paragraph text. Applied by `ParagraphUIView.setTextHighlights`.
public struct TextHighlight: Hashable, Sendable {
  /// Exact substring of the rendered text to highlight (all occurrences).
  public let quote: String
  /// Background color (callers should pass a low-alpha color for fill / background / pen).
  public let color: PlatformColor
  public let style: TextHighlightStyle
  /// Stable id of the stroke: seeds the pen shape so it doesn't wobble between repaints.
  public let strokeId: String

  public init(quote: String, color: PlatformColor, style: TextHighlightStyle = .background, strokeId: String = "") {
    self.quote = quote
    self.color = color
    self.style = style
    self.strokeId = strokeId.isEmpty ? quote : strokeId
  }
}

/// Where a highlight quote is painted inside one text view's plain text. Shared by the UIKit and
/// AppKit paragraph views (`reapplyHighlights`).
///
/// A quote is stored as the selected text (H1: storage unchanged). A cross-paragraph quote joins its
/// paragraphs with `\n`, so when one view does not contain it whole (one paragraph per view: bubble
/// mode, segmented text, merge off) it is matched piecewise: the quote's leading pieces only against
/// the end of this view's text, its trailing pieces only against the start, and inner pieces only
/// when they equal this view's whole text.
enum TextHighlightMatcher {
  static func ranges(of quote: String, in text: NSString) -> [NSRange] {
    guard !quote.isEmpty else { return [] }
    // 1. Whole quote: every occurrence (same scan the views always did — single-paragraph quotes unchanged)
    func occurrences(_ needle: String) -> [NSRange] {
      var found: [NSRange] = []
      var search = NSRange(location: 0, length: text.length)
      while true {
        let range = text.range(of: needle, options: [], range: search)
        guard range.location != NSNotFound, range.length > 0 else { break }
        found.append(range)
        let next = NSMaxRange(range)
        guard next < text.length else { break }
        search = NSRange(location: next, length: text.length - next)
      }
      return found
    }
    var result = occurrences(quote)
    guard result.isEmpty else { return result }
    // rendered paragraphs are joined by \n; a quote carrying \r\n still counts as the same text
    let normalized = quote.replacingOccurrences(of: "\r\n", with: "\n")
    if normalized != quote {
      result = occurrences(normalized)
      guard result.isEmpty else { return result }
    }

    // 2. Cross-paragraph quote not contained whole: edge-anchored pieces
    let pieces = (normalized as NSString).components(separatedBy: "\n")
    let k = pieces.count
    guard k > 1, text.length > 0 else { return [] }
    func joined(_ from: Int, _ to: Int) -> String { pieces[from...to].joined(separator: "\n") }
    let full = NSRange(location: 0, length: text.length)
    // leading pieces q1…qj (j < k) = this view's ending; longest wins
    for j in stride(from: k - 2, through: 0, by: -1) {
      let head = joined(0, j)
      guard !head.isEmpty else { continue }
      let found = text.range(of: head, options: [.anchored, .backwards], range: full)
      if found.location != NSNotFound, found.length > 0 {
        result.append(found)
        break
      }
    }
    // trailing pieces qi…qk (i > 1) = this view's beginning; longest wins
    for i in 1..<k {
      let tail = joined(i, k - 1)
      guard !tail.isEmpty else { continue }
      let found = text.range(of: tail, options: [.anchored], range: full)
      if found.location != NSNotFound, found.length > 0 {
        if !result.contains(found) { result.append(found) }
        break
      }
    }
    // inner pieces qi…qj (1 < i ≤ j < k) = this view's whole text
    if result.isEmpty, k > 2 {
      outer: for i in 1..<(k - 1) {
        for j in i..<(k - 1) {
          let middle = joined(i, j)
          guard !middle.isEmpty else { continue }
          if text.range(of: middle, options: [.anchored], range: full) == full {
            result.append(full)
            break outer
          }
        }
      }
    }
    return result
  }
}

/// Geometry of layer-drawn strokes, shared by the UIKit and AppKit paragraph views
/// (both draw in flipped coordinates: y grows downwards).
enum TextHighlightGeometry {
  /// One drawn stroke over one line segment.
  struct Piece {
    let path: CGPath
    let color: CGColor
  }

  /// - Parameters:
  ///   - rects: the stroke's per-line segment frames (text container coordinates)
  ///   - layer: underline step (0 = right under the text)
  static func pieces(style: TextHighlightStyle, color: CGColor, strokeId: String, layer: Int, rects: [CGRect]) -> [Piece] {
    rects.enumerated().compactMap { index, r in
      let path: CGPath
      switch style {
      case .background:
        return nil
      case .fill:
        path = CGPath(rect: r, transform: nil)
      case .underline:
        path = CGPath(rect: CGRect(x: r.minX, y: r.maxY - 1 + CGFloat(layer) * 3, width: r.width, height: 1.8), transform: nil)
      case .pen:
        path = penPath(in: r, seed: seed(strokeId, index))
      }
      return Piece(path: path, color: color)
    }
  }

  /// Marker stroke over the lower half of the line, top and bottom edges slightly wobbly.
  /// Same shape recipe as the book reader's pen (ChapterHTMLRenderer.penStroke / PDF PenStrokeAnnotation).
  static func penPath(in r: CGRect, seed: UInt64) -> CGPath {
    var h = seed
    func j(_ spread: CGFloat) -> CGFloat {
      h = h &* 6364136223846793005 &+ 1442695040888963407
      return (CGFloat(h >> 33) / CGFloat(1 << 31) - 0.5) * spread
    }
    let top = r.minY + r.height * 0.45, bottom = r.maxY - r.height * 0.04
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + j(2), y: top + j(r.height * 0.08)))
    p.addQuadCurve(to: CGPoint(x: r.maxX + j(2), y: top + j(r.height * 0.08)),
                   control: CGPoint(x: r.midX, y: top + j(r.height * 0.14)))
    p.addLine(to: CGPoint(x: r.maxX + j(2), y: bottom + j(r.height * 0.06)))
    p.addQuadCurve(to: CGPoint(x: r.minX + j(2), y: bottom + j(r.height * 0.06)),
                   control: CGPoint(x: r.midX, y: bottom + j(r.height * 0.1)))
    p.closeSubpath()
    return p
  }

  static func seed(_ id: String, _ index: Int) -> UInt64 {
    var h: UInt64 = 1469598103934665603
    for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
    return h &+ UInt64(index) &* 0x9E3779B97F4A7C15
  }

  /// Underline steps: each underline occurrence takes the lowest step not used by an
  /// overlapping underline occurrence drawn before it.
  static func underlineLayers(_ ranges: [NSRange]) -> [Int] {
    var placed: [(NSRange, Int)] = []
    return ranges.map { r in
      let busy = Set(placed.filter { NSIntersectionRange($0.0, r).length > 0 }.map(\.1))
      var k = 0
      while busy.contains(k) { k += 1 }
      placed.append((r, k))
      return k
    }
  }
}
