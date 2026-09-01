import Foundation

/// A parsed edit-tool result (`edit_file` / `write_file` / `multi_edit`): a summary/header line, the
/// changed-line counts, and the `+`/`-`/context lines — enough to render the change as a coloured
/// diff. The wire form is the `tool_result` *content* (no metadata); see protocol §9.
public struct EditDiff: Sendable, Equatable {
    public let summary: String
    public let added: Int
    public let removed: Int
    public let lines: [Line]

    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case add, remove, context }
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public init(summary: String, added: Int, removed: Int, lines: [Line]) {
        self.summary = summary
        self.added = added
        self.removed = removed
        self.lines = lines
    }
}

extension EditDiff {
    /// Parse an edit tool's result content, or `nil` if it isn't one. Anchored to the edit tools'
    /// output — a `(+N -M)` summary or an "applied edits to …" header — so arbitrary tool output
    /// (a file read whose lines happen to start with `- `, say) isn't mistaken for a diff.
    public static func parse(_ content: String) -> EditDiff? {
        let raw = content.components(separatedBy: "\n")
        guard let first = raw.first, isEditHeader(first) else { return nil }

        // `lines` is the body after the summary; the summary is surfaced separately.
        let lines = raw.dropFirst().map(classify)
        let added = lines.filter { $0.kind == .add }.count
        let removed = lines.filter { $0.kind == .remove }.count
        return EditDiff(summary: first, added: added, removed: removed, lines: lines)
    }

    private static func isEditHeader(_ line: String) -> Bool {
        line.range(of: #"\(\+\d+ -\d+\)"#, options: .regularExpression) != nil
            || line.hasPrefix("applied edits to ")
    }

    private static func classify(_ line: String) -> Line {
        if line.hasPrefix("+ ") { return Line(kind: .add, text: String(line.dropFirst(2))) }
        if line.hasPrefix("- ") { return Line(kind: .remove, text: String(line.dropFirst(2))) }
        if line.hasPrefix("  ") { return Line(kind: .context, text: String(line.dropFirst(2))) }
        return Line(kind: .context, text: line)
    }
}
