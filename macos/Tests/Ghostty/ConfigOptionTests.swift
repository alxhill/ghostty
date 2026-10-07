import Testing
@testable import Ghostty
@testable import GhosttyKit

@Suite
struct ConfigOptionTests {
    private func option(_ name: String) throws -> Ghostty.ConfigOption {
        try #require(Ghostty.ConfigOption.all.first { $0.name == name })
    }

    @Test func describesEveryOption() {
        let names = Ghostty.ConfigOption.all.map(\.name)
        #expect(names.count > 100)
        #expect(Set(names).count == names.count)
    }

    @Test func describesKinds() throws {
        #expect(try option("font-size").kind == .float)
        #expect(try option("window-height").kind == .int)
        #expect(try option("maximize").kind == .bool)
        #expect(try option("background").kind == .color)
        #expect(try option("theme").kind == .string)

        let theme = try option("window-theme")
        #expect(theme.kind == .enumeration)
        #expect(theme.choices.contains("dark"))

        let features = try option("shell-integration-features")
        #expect(features.kind == .flags)
        #expect(features.choices.contains("cursor"))

        let blink = try option("cursor-style-blink")
        #expect(blink.kind == .bool)
        #expect(blink.optional)

        #expect(try option("keybind").repeatable)
        #expect(try !option("font-size").repeatable)
        #expect(try option("font-size").summary.hasPrefix("Font size in points."))
    }

    @Test func formatsValues() throws {
        let config = try TemporaryConfig("""
        font-size = 15
        font-family = A
        font-family = B
        """)

        #expect(config.formattedValue("font-size") == "15")
        #expect(config.formattedValue("font-family") == "A\nB")
        #expect(config.formattedValue("title") == "")
        #expect(config.formattedValue("not-a-real-option") == "")
    }

    @Test func detectsChangesFromDefault() throws {
        let config = try TemporaryConfig("font-size = 15")
        let defaults = try TemporaryConfig("")

        #expect(config.valueChanged("font-size", from: defaults))
        #expect(!config.valueChanged("maximize", from: defaults))
    }

    @Test func defaultFilePaths() {
        let paths = Ghostty.Config.defaultFilePaths
        #expect(paths.count == 4)
        #expect(paths.first?.hasSuffix("ghostty/config") == true)
        #expect(paths.last?.hasSuffix("config.ghostty") == true)
    }
}
