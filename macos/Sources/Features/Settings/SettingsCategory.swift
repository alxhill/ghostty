import Foundation

/// Groups configuration options in the settings window. Ghostty's config has
/// no categories of its own so these are derived from option names.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case font
    case colors
    case background
    case cursor
    case window
    case mouse
    case clipboard
    case keyboard
    case shell
    case terminal
    case notifications
    case quickTerminal
    case macOS
    case linux
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .font: "Font"
        case .colors: "Colors"
        case .background: "Background"
        case .cursor: "Cursor"
        case .window: "Window"
        case .mouse: "Mouse & Selection"
        case .clipboard: "Clipboard"
        case .keyboard: "Keyboard"
        case .shell: "Shell & Command"
        case .terminal: "Terminal"
        case .notifications: "Bell & Notifications"
        case .quickTerminal: "Quick Terminal"
        case .macOS: "macOS"
        case .linux: "Linux & GTK"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .font: "textformat"
        case .colors: "paintpalette"
        case .background: "photo"
        case .cursor: "character.cursor.ibeam"
        case .window: "macwindow"
        case .mouse: "cursorarrow.rays"
        case .clipboard: "doc.on.clipboard"
        case .keyboard: "keyboard"
        case .shell: "apple.terminal"
        case .terminal: "text.alignleft"
        case .notifications: "bell"
        case .quickTerminal: "rectangle.topthird.inset.filled"
        case .macOS: "apple.logo"
        case .linux: "desktopcomputer"
        case .other: "ellipsis.circle"
        }
    }

    /// The category for an option name. Patterns ending in `*` match prefixes,
    /// and the first matching rule wins.
    init(option name: String) {
        for (category, patterns) in Self.rules where patterns.contains(where: { Self.matches(name, $0) }) {
            self = category
            return
        }

        self = .other
    }

    private static func matches(_ name: String, _ pattern: String) -> Bool {
        if pattern.hasSuffix("*") {
            return name.hasPrefix(pattern.dropLast())
        }

        return name == pattern
    }

    private static let rules: [(SettingsCategory, [String])] = [
        (.keyboard, ["keybind", "key-remap", "command-palette-entry", "macos-option-as-alt"]),
        (.quickTerminal, ["quick-terminal-*", "gtk-quick-terminal-*"]),
        (.general, [
            "language",
            "config-file",
            "config-default-files",
            "initial-window",
            "quit-after-last-window-closed*",
            "confirm-close-surface",
            "undo-timeout",
            "working-directory",
            "window-inherit-working-directory",
            "tab-inherit-working-directory",
            "split-inherit-working-directory",
            "window-inherit-font-size",
        ]),
        (.colors, [
            "theme",
            "background",
            "foreground",
            "palette*",
            "selection-foreground",
            "selection-background",
            "bold-color",
            "faint-opacity",
            "minimum-contrast",
            "search-*",
            "alpha-blending",
            "window-colorspace",
            "split-divider-color",
            "unfocused-split-fill",
        ]),
        (.background, ["background-*", "unfocused-split-opacity"]),
        (.cursor, ["cursor-*"]),
        (.font, ["font-*", "adjust-*", "grapheme-width-method", "freetype-load-flags"]),
        (.notifications, [
            "bell-*",
            "desktop-notifications",
            "app-notifications",
            "notify-on-command-finish*",
            "progress-style",
        ]),
        (.mouse, [
            "mouse-*",
            "click-repeat-interval",
            "copy-on-select",
            "right-click-action",
            "middle-click-action",
            "focus-follows-mouse",
            "selection-*",
            "link",
            "link-*",
        ]),
        (.clipboard, ["clipboard-*"]),
        (.shell, [
            "command",
            "initial-command",
            "shell-integration*",
            "env",
            "input",
            "wait-after-command",
            "abnormal-command-exit-runtime",
            "term",
            "enquiry-response",
        ]),
        (.terminal, [
            "scrollback-*",
            "scrollbar",
            "scroll-to-bottom",
            "vt-*",
            "title-report",
            "image-storage-limit",
            "osc-color-report-format",
            "custom-shader*",
        ]),
        (.window, [
            "window-*",
            "maximize",
            "fullscreen",
            "title",
            "resize-overlay*",
            "drag-handle",
            "split-*",
        ]),
        (.macOS, ["macos-*", "auto-update*"]),
        (.linux, ["gtk-*", "linux-*", "x11-*", "class", "async-backend"]),
    ]
}
