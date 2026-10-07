import Foundation

/// A Ghostty configuration file that can be edited while preserving the
/// comments, ordering, and formatting of every line that isn't changed.
struct ConfigFile: Equatable {
    struct Entry: Equatable {
        let line: Int
        let key: String
        let value: String
    }

    let url: URL
    private(set) var lines: [String]

    init(url: URL, contents: String) {
        self.url = url
        var lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
    }

    /// Load the file at the given URL. A missing file is treated as empty.
    static func load(_ url: URL) throws -> ConfigFile {
        do {
            return ConfigFile(url: url, contents: try String(contentsOf: url, encoding: .utf8))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ConfigFile(url: url, contents: "")
        }
    }

    var contents: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    var entries: [Entry] {
        lines.enumerated().compactMap { Self.parse($1, at: $0) }
    }

    func values(for key: String) -> [String] {
        entries.filter { $0.key == key }.map(\.value)
    }

    /// Replace every value for the key. Existing lines are updated in place so
    /// their position and surrounding comments are kept. Extra lines are removed
    /// and new ones are added after the last existing line, or at the end.
    mutating func set(_ key: String, values: [String]) {
        let existing = entries.filter { $0.key == key }.map(\.line)
        for (line, value) in zip(existing, values) {
            lines[line] = Self.format(key: key, value: value)
        }

        if values.count > existing.count {
            let added = values[existing.count...].map { Self.format(key: key, value: $0) }
            if let last = existing.last {
                lines.insert(contentsOf: added, at: last + 1)
            } else {
                lines.append(contentsOf: added)
            }
        } else {
            for line in existing[values.count...].reversed() {
                lines.remove(at: line)
            }
        }
    }

    mutating func remove(_ key: String) {
        set(key, values: [])
    }

    /// Write the file, following symlinks so a linked config (e.g. from a
    /// dotfiles repository) is updated rather than replaced.
    func write() throws {
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    // MARK: Parsing

    private static let whitespace = CharacterSet(charactersIn: " \t")

    /// Parse a line the same way libghostty does: blank lines and lines starting
    /// with `#` are ignored, and a value wrapped in double quotes is unquoted.
    static func parse(_ line: String, at index: Int) -> Entry? {
        let trimmed = line.trimmingCharacters(in: whitespace.union(CharacterSet(charactersIn: "\r")))
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else {
            return Entry(line: index, key: trimmed, value: "")
        }

        let key = trimmed[..<eq].trimmingCharacters(in: whitespace)
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: whitespace)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }

        return Entry(line: index, key: key, value: value)
    }

    /// Format a line, quoting values whose surrounding whitespace would
    /// otherwise be trimmed.
    static func format(key: String, value: String) -> String {
        let needsQuotes = value != value.trimmingCharacters(in: whitespace)
        return "\(key) = \(needsQuotes ? "\"\(value)\"" : value)"
    }
}
