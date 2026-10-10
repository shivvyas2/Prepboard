import Foundation

extension String {
    /// The text without emoji (PrepBoard's content standard). Keeps typographic symbols the app uses:
    /// ✓ ✗ ★ • — → © ® ™, digits, # and *. "1️⃣" becomes "1". Indentation and code are untouched.
    var withoutEmoji: String {
        var out = String.UnicodeScalarView()
        var dropped = false
        for s in unicodeScalars {
            let v = s.value
            let p = s.properties
            let drop = p.isEmojiPresentation
                || (p.isEmoji && v >= 0x2300 && !(0x2190...0x21FF).contains(v))
                || p.isEmojiModifier
                || v == 0xFE0F || v == 0x20E3 || v == 0x200D
                || (0xE0020...0xE007F).contains(v)
            if drop { dropped = true; continue }
            // Skip the one space an emoji leaves behind ("🚀 Launch" → "Launch", "Done 🎉 now" → "Done now").
            if dropped, s == " ", out.isEmpty || out.last == " " || out.last == "\n" { dropped = false; continue }
            dropped = false
            out.append(s)
        }
        return String(out)
    }
}
