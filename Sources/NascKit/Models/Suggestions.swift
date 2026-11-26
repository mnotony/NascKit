import Foundation

/// The model's alternatives to a call, as an approval card shows them (nasc
/// `docs/plans/approval-choices.md` § Suggestions).
///
/// ogma cleans them before they ride `input_requested.metadata.suggestions`; a client applies the
/// same rule again (ogma's `Ogma.Suggestions`, nasc's `Nasc.Suggestions`, nasc-cli's `suggest.rs`),
/// because another agent or an ogma bug must not get past it, and what is shown is exactly what is
/// sent when one is picked. It works on Unicode scalars throughout, as the other copies do: Swift's
/// `String` compares grapheme clusters (and canonical equivalents), which would keep `Yes⃝` or read
/// `café` and `café` as one.
public enum Suggestions {
    static let most = 2
    static let longest = 80

    /// The question's suggestions: strings only, cleaned, two at most.
    public static func fromMetadata(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else { return [] }
        return clean(items.compactMap { $0 as? String })
    }

    /// The one cleaning rule, in order; the first two that survive are kept.
    public static func clean<S: Sequence>(_ items: S) -> [String] where S.Element == String {
        var kept: [String] = []
        for item in items {
            let text = tidy(item)
            if dropped(text) || kept.contains(where: { scalars(lower($0)) == scalars(lower(text)) }) {
                continue
            }
            kept.append(text)
            if kept.count == most { break }
        }
        return kept
    }

    private static func tidy(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in withoutEscapes(Array(text.unicodeScalars)) {
            switch s.value {
            case 0x09, 0x0A, 0x0D, 0x85, 0x2028, 0x2029: scalars.append(" ")
            default: if !hidden(s) { scalars.append(s) }
            }
        }
        // collapse whitespace by scalar, so a combining mark after a space can't hide it
        var collapsed = String.UnicodeScalarView()
        var gap = false
        for s in scalars {
            if s.properties.isWhitespace {
                gap = !collapsed.isEmpty
            } else {
                if gap { collapsed.append(" ") }
                gap = false
                collapsed.append(s)
            }
        }
        return stripMarkers(String(collapsed))
    }

    /// Controls, format characters (bidi controls, zero-width characters: a ZWJ emoji sequence
    /// comes apart) and every variation selector.
    private static func hidden(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .format: return true
        default: return (0xFE00...0xFE0F).contains(s.value) || (0xE0100...0xE01EF).contains(s.value)
        }
    }

    /// ESC or C1 CSI/OSC with their parameters, or another two-byte escape, removed whole.
    private static func withoutEscapes(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        func at(_ j: Int) -> UInt32? { j < s.count ? s[j].value : nil }
        while i < s.count {
            let c = s[i].value
            let next = at(i + 1)
            var csiStart: Int?
            if c == 0x1B, next == 0x5B { csiStart = i + 2 } else if c == 0x9B { csiStart = i + 1 }
            if let start = csiStart {
                var j = start
                while let v = at(j), (0x30...0x3F).contains(v) { j += 1 }
                while let v = at(j), (0x20...0x2F).contains(v) { j += 1 }
                if let v = at(j), (0x40...0x7E).contains(v) {
                    i = j + 1
                    continue
                }
            }
            var oscStart: Int?
            if c == 0x1B, next == 0x5D { oscStart = i + 2 } else if c == 0x9D { oscStart = i + 1 }
            if let start = oscStart {
                var j = start
                while let v = at(j), v != 0x07, v != 0x1B, v != 0x9C { j += 1 }
                switch (at(j), at(j + 1)) {
                case (0x07?, _), (0x9C?, _): i = j + 1
                case (0x1B?, 0x5C?): i = j + 2
                default: i = j
                }
                continue
            }
            if c == 0x1B, let n = next, (0x40...0x5A).contains(n) || (0x5C...0x5F).contains(n) {
                i += 2
                continue
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    /// Leading list markers, each with the space after it, again and again: `- 1. ❯ List it` is
    /// `List it`, while `--dry-run first` and `2 files only` stay whole.
    private static func stripMarkers(_ text: String) -> String {
        var s = Array(text.unicodeScalars)
        while let first = s.first {
            var length = 0
            if "-*•❯›>▶➤→".unicodeScalars.contains(first) {
                length = 1
            } else {
                let digits = s.prefix(while: { $0.properties.numericType == .decimal }).count
                if digits > 0, digits < s.count, s[digits] == "." || s[digits] == ")" { length = digits + 1 }
            }
            guard length > 0, length < s.count, s[length] == " " else { break }
            s.removeFirst(length + 1)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s)
        return String(view)
    }

    /// Dropped, never cut, so what is shown is what is sent.
    private static func dropped(_ text: String) -> Bool {
        let l = scalars(lower(text).replacingOccurrences(of: "ſ", with: "s"))
        func starts(_ word: String) -> Bool { l.starts(with: word.unicodeScalars) }
        return text.unicodeScalars.isEmpty
            || text.unicodeScalars.count > longest
            || combiningRun(text)
            || text.unicodeScalars.contains("❯")
            || starts("remember:") || starts("forget:")
            || ["yes", "approve", "approved", "go ahead"].contains { startsWithWord(l, $0) }
            || ["run it", "proceed"].contains { scalars($0) == trimmedEnd(l) }
            || starts("tell it what to do instead") || starts("chat about this")
    }

    private static func lower(_ text: String) -> String { text.lowercased() }

    private static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    private static func startsWithWord(_ text: [Unicode.Scalar], _ word: String) -> Bool {
        let w = scalars(word)
        guard text.starts(with: w) else { return false }
        guard w.count < text.count else { return true }
        let next = text[w.count]
        switch next.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .connectorPunctuation:
            return false
        default:
            return true
        }
    }

    private static func trimmedEnd(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var s = text
        while let last = s.last, last.properties.isWhitespace || isPunctuation(last) { s.removeLast() }
        return s
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII, s.properties.generalCategory != .control,
           !CharacterSet.alphanumerics.contains(s), !s.properties.isWhitespace {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func combiningRun(_ text: String) -> Bool {
        var run = 0
        for s in text.unicodeScalars {
            run = s.properties.generalCategory == .nonspacingMark ? run + 1 : 0
            if run > 2 { return true }
        }
        return false
    }
}
