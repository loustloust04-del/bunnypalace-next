#if os(macOS)
import AppKit
import SwiftStreamingMarkdown

/// Font matching is a resource operation, not per-message render work. Cache only
/// immutable font sets; colors, highlights and menu callbacks remain view-local.
final class MacMarkdownFontResolver {
    static let shared = MacMarkdownFontResolver()

    struct Key: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
    }
    private final class CacheKey: NSObject {
        let value: Key
        init(_ value: Key) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? CacheKey)?.value == value
        }
    }
    private final class Entry {
        let fonts: TextFonts
        init(_ fonts: TextFonts) { self.fonts = fonts }
    }

    private let cache = NSCache<CacheKey, Entry>()
    private let resolve: (Key) -> TextFonts

    init(limit: Int = 128, resolve: @escaping (Key) -> TextFonts = MacMarkdownFontResolver.makeFonts) {
        cache.countLimit = limit
        self.resolve = resolve
    }

    func fonts(name: String, size: CGFloat, weight: NSFont.Weight) -> TextFonts {
        let key = CacheKey(Key(name: name, size: size, weight: weight.rawValue))
        if let entry = cache.object(forKey: key) { return entry.fonts }
        let fonts = resolve(key.value)
        cache.setObject(Entry(fonts), forKey: key)
        return fonts
    }

    func invalidate() { cache.removeAllObjects() }

    static func makeFonts(_ key: Key) -> TextFonts {
        let normal: NSFont
        let bold: NSFont?
        let italic: NSFont?
        let boldItalic: NSFont?
        let weight = NSFont.Weight(rawValue: key.weight)
        if key.name.isEmpty {
            normal = .systemFont(ofSize: key.size, weight: weight)
            bold = .systemFont(ofSize: key.size, weight: weight == .regular ? .semibold : .bold)
            italic = NSFont(descriptor: normal.fontDescriptor.withSymbolicTraits(.italic), size: key.size)
            boldItalic = bold.flatMap {
                NSFont(descriptor: $0.fontDescriptor.withSymbolicTraits(.italic), size: key.size)
            }
        } else {
            let descriptor = NSFontDescriptor(name: key.name, size: key.size)
            let resolvedBase = NSFont(descriptor: descriptor, size: key.size)
            normal = resolvedBase ?? .systemFont(ofSize: key.size, weight: weight)
            func variant(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
                guard let font = NSFont(descriptor: descriptor.withSymbolicTraits(traits), size: key.size),
                      font.fontName != resolvedBase?.fontName else { return nil }
                return font
            }
            bold = variant(.bold)
            italic = variant(.italic)
            boldItalic = variant([.bold, .italic])
        }
        return TextFonts(normal: normal, italic: italic, bold: bold, boldItalic: boldItalic,
                         preferredLetterSpacing: nil, preferredLineHeight: nil)
    }
}
#endif
