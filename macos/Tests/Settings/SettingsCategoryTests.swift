import Testing
@testable import Ghostty

@Suite
struct SettingsCategoryTests {
    @Test(arguments: [
        ("font-family", SettingsCategory.font),
        ("adjust-cell-height", .font),
        ("background", .colors),
        ("palette", .colors),
        ("selection-background", .colors),
        ("background-opacity", .background),
        ("cursor-color", .cursor),
        ("window-padding-x", .window),
        ("window-inherit-working-directory", .general),
        ("selection-clear-on-copy", .mouse),
        ("keybind", .keyboard),
        ("macos-option-as-alt", .keyboard),
        ("quick-terminal-position", .quickTerminal),
        ("gtk-quick-terminal-layer", .quickTerminal),
        ("macos-titlebar-style", .macOS),
        ("gtk-titlebar", .linux),
        ("notify-on-command-finish-after", .notifications),
        ("shell-integration-features", .shell),
        ("not-a-real-option", .other),
    ])
    func categorizesOption(name: String, category: SettingsCategory) {
        #expect(SettingsCategory(option: name) == category)
    }

    @Test(arguments: [
        ("gtk-titlebar", false),
        ("gtk-quick-terminal-layer", false),
        ("window-titlebar-background", false),
        ("class", false),
        ("window-theme", true),
        ("macos-titlebar-style", true),
        ("quit-after-last-window-closed", true),
    ])
    func detectsGTKOnlyOptions(name: String, supported: Bool) {
        #expect(SettingsCategory.isSupportedOnMacOS(name) == supported)
    }

    @Test func gtkOnlyOptionsExist() {
        let names = Set(Ghostty.ConfigOption.all.map(\.name))
        let missing = SettingsCategory.gtkOnly.filter { pattern in
            pattern.hasSuffix("*")
                ? !names.contains { $0.hasPrefix(pattern.dropLast()) }
                : !names.contains(pattern)
        }
        #expect(missing == [])
    }

    @Test func everyOptionHasACategory() {
        let uncategorized = Ghostty.ConfigOption.all
            .map(\.name)
            .filter { SettingsCategory(option: $0) == .other }
        #expect(uncategorized == [])
    }
}
