import Foundation
import Testing
@testable import Ghostty

@Suite
struct ConfigFileTests {
    private func file(_ contents: String) -> ConfigFile {
        ConfigFile(url: URL(fileURLWithPath: "/tmp/config.ghostty"), contents: contents)
    }

    // MARK: - Parsing

    @Test func parsesEntriesLikeLibghostty() {
        let config = file("""
        # A comment
          font-size   =  14\t

        font-family = "  Fira Code  "
        keybind = ctrl+a=text:=
        title=
        maximize\r
        """)

        #expect(config.entries == [
            .init(line: 1, key: "font-size", value: "14"),
            .init(line: 3, key: "font-family", value: "  Fira Code  "),
            .init(line: 4, key: "keybind", value: "ctrl+a=text:="),
            .init(line: 5, key: "title", value: ""),
            .init(line: 6, key: "maximize", value: ""),
        ])
    }

    @Test func valuesForRepeatedKey() {
        let config = file("""
        font-family = A
        font-size = 12
        font-family = B
        """)

        #expect(config.values(for: "font-family") == ["A", "B"])
        #expect(config.values(for: "theme") == [])
    }

    @Test func unchangedContentsRoundTrip() {
        let contents = "# Comment\n\nfont-size = 14\n"
        #expect(file(contents).contents == contents)
        #expect(file("").contents == "")
    }

    // MARK: - Editing

    @Test func setUpdatesInPlace() {
        var config = file("""
        # Font
        font-size = 14
        # Colors
        background = #000000
        """)

        config.set("font-size", values: ["16"])
        #expect(config.contents == """
        # Font
        font-size = 16
        # Colors
        background = #000000

        """)
    }

    @Test func setCollapsesDuplicates() {
        var config = file("""
        font-size = 12
        theme = dark
        font-size = 14
        """)

        config.set("font-size", values: ["16"])
        #expect(config.contents == "font-size = 16\ntheme = dark\n")
    }

    @Test func setAppendsNewKeys() {
        var config = file("font-size = 14")
        config.set("theme", values: ["Dracula"])
        #expect(config.contents == "font-size = 14\ntheme = Dracula\n")
    }

    @Test func setInsertsRepeatedValuesAfterExisting() {
        var config = file("""
        keybind = a=b
        # end of keybinds
        font-size = 14
        """)

        config.set("keybind", values: ["a=b", "c=d"])
        #expect(config.contents == """
        keybind = a=b
        keybind = c=d
        # end of keybinds
        font-size = 14

        """)
    }

    @Test func setRemovesExtraValues() {
        var config = file("""
        keybind = a=b
        font-size = 14
        keybind = c=d
        keybind = e=f
        """)

        config.set("keybind", values: ["x=y"])
        #expect(config.contents == "keybind = x=y\nfont-size = 14\n")
    }

    @Test func removeDeletesEveryLine() {
        var config = file("""
        font-size = 12
        # keep me
        font-size = 14
        """)

        config.remove("font-size")
        #expect(config.contents == "# keep me\n")
    }

    @Test func formatQuotesSurroundingWhitespace() {
        #expect(ConfigFile.format(key: "font-size", value: "14") == "font-size = 14")
        #expect(ConfigFile.format(key: "title", value: " padded ") == "title = \" padded \"")
        #expect(ConfigFile.format(key: "selection-word-chars", value: "\t'\"") == "selection-word-chars = \"\t'\"\"")
    }

    // MARK: - Disk

    @Test func loadMissingFileIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try ConfigFile.load(url)
        #expect(config.entries.isEmpty)
    }

    @Test func writeFollowsSymlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("dotfiles.ghostty")
        try "font-size = 12\n".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("config.ghostty")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        var config = try ConfigFile.load(link)
        config.set("font-size", values: ["14"])
        try config.write()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "font-size = 14\n")
    }
}
