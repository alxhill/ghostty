import Testing
@testable import Ghostty

@Suite
struct SettingsFormatTests {
    @Test func paragraphsUnwrapLines() {
        let help = """
        The first line
        continues here.

        Second paragraph.
        """

        #expect(SettingsFormat.paragraphs(help) == [
            "The first line continues here.",
            "Second paragraph.",
        ])
    }

    @Test func paragraphsKeepListItems() {
        let help = """
        Valid values:
        * `one` - The first
          value.
        * `two` - The second.
        """

        #expect(SettingsFormat.paragraphs(help) == [
            "Valid values:\n• `one` - The first value.\n• `two` - The second.",
        ])
    }

    @Test func paragraphsFormatCode() {
        let help = """
        Run:

            ghostty +list-fonts
            font-family = `quoted`
        """

        #expect(SettingsFormat.paragraphs(help) == [
            "Run:",
            "`ghostty +list-fonts`\nfont-family = `quoted`",
        ])
    }

    @Test func paragraphsFormatFencedCode() {
        let help = """
        For example:

        ```ini
        config-file = "foo"
        a = 1
        ```
        """

        #expect(SettingsFormat.paragraphs(help) == [
            "For example:",
            "`config-file = \"foo\"`\n`a = 1`",
        ])
    }
}
