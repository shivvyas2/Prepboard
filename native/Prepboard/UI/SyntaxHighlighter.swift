import Foundation
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// Light-theme syntax colors for the Practice editor (Swift, Python, JavaScript), in the style of
/// LeetCode's and Xcode's light editors. Colors text in place, so the cursor and undo stay put.
enum SyntaxHighlighter {
    private static func rgb(_ hex: UInt32) -> PlatformColor {
        PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static let plain = rgb(0x1D1A16)
    static let keyword = rgb(0x9B2393)     // magenta
    static let type = rgb(0x0B4F79)        // dark teal
    static let function = rgb(0x326D74)    // teal
    static let string = rgb(0xC41A16)      // red
    static let number = rgb(0x1C00CF)      // blue
    static let comment = rgb(0x5D6C79)     // grey
    static let attribute = rgb(0x815F03)   // ochre: @decorators, #if, self

    private static let keywords: [CodeLang: [String]] = [
        .swift: ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case", "default", "break",
                 "continue", "struct", "class", "enum", "protocol", "extension", "init", "deinit", "import", "where", "as", "is", "try",
                 "catch", "throw", "throws", "rethrows", "async", "await", "inout", "static", "private", "fileprivate", "public", "internal",
                 "mutating", "override", "final", "lazy", "weak", "nil", "true", "false", "self", "Self", "super", "some", "any", "defer", "do",
                 "typealias", "associatedtype", "subscript", "operator", "convenience", "required", "open"],
        .python: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None", "True", "False",
                  "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "pass", "break", "continue",
                  "global", "nonlocal", "assert", "del", "async", "await", "self"],
        .javascript: ["function", "const", "let", "var", "if", "else", "return", "for", "of", "in", "while", "do", "switch", "case", "default",
                      "break", "continue", "class", "extends", "new", "this", "super", "null", "undefined", "true", "false", "typeof",
                      "instanceof", "try", "catch", "finally", "throw", "async", "await", "yield", "import", "export", "from", "static", "get", "set"],
    ]

    private struct Rule { let regex: NSRegularExpression; let color: PlatformColor; var group = 0 }

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: opts)
    }

    private static let rules: [CodeLang: [Rule]] = {
        var out: [CodeLang: [Rule]] = [:]
        for lang in CodeLang.allCases {
            let kw = keywords[lang]!.joined(separator: "|")
            var r: [Rule] = [
                Rule(regex: re(#"\b[A-Z][A-Za-z0-9_]*\b"#), color: type),
                Rule(regex: re(#"\b([a-z_][A-Za-z0-9_]*)\s*(?=\()"#), color: function, group: 1),
                Rule(regex: re(#"\b(\#(kw))\b"#), color: keyword),
                Rule(regex: re(#"\b(0x[0-9A-Fa-f_]+|\d[\d_]*(\.\d+)?)\b"#), color: number),
            ]
            switch lang {
            case .swift:
                r.append(Rule(regex: re(#"(@\w+|#\w+)"#), color: attribute))
                r.append(Rule(regex: re(#""""[\s\S]*?"""|"(?:\\.|[^"\\\n])*""#), color: string))
                r.append(Rule(regex: re(#"//[^\n]*|/\*[\s\S]*?\*/"#), color: comment))
            case .python:
                r.append(Rule(regex: re(#"(@\w+)"#), color: attribute))
                r.append(Rule(regex: re(#"[rbfu]{0,2}("""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#), color: string))
                r.append(Rule(regex: re(#"#[^\n]*"#), color: comment))
            case .javascript:
                r.append(Rule(regex: re(#"`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#), color: string))
                r.append(Rule(regex: re(#"//[^\n]*|/\*[\s\S]*?\*/"#), color: comment))
            }
            out[lang] = r
        }
        return out
    }()

    /// Recolors the whole text. Strings and comments are applied last, so keywords inside them stay plain.
    static func highlight(_ storage: NSTextStorage, lang: CodeLang, font: PlatformFont) {
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: plain], range: full)
        for rule in rules[lang] ?? [] {
            rule.regex.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m else { return }
                let range = m.range(at: rule.group)
                if range.location != NSNotFound { storage.addAttribute(.foregroundColor, value: rule.color, range: range) }
            }
        }
        storage.endEditing()
    }
}
