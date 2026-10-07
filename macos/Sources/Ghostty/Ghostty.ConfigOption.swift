import Foundation
import GhosttyKit

extension Ghostty {
    /// Describes a single configuration option as reported by libghostty.
    struct ConfigOption: Identifiable, Hashable {
        enum Kind {
            case bool
            case int
            case float
            /// A single value from `choices`.
            case enumeration
            /// A comma-separated set of `choices`, each optionally prefixed with `no-`.
            case flags
            case color
            case string
        }

        let name: String
        let help: String
        let kind: Kind

        /// True if the option can be unset, in which case it has no value.
        let optional: Bool

        /// True if the option can be specified multiple times, each adding a value.
        let repeatable: Bool

        /// Valid values for `enumeration` and `flags` options.
        let choices: [String]

        var id: String { name }

        /// The first paragraph of the help text.
        var summary: String {
            let paragraph = help.components(separatedBy: "\n\n").first ?? ""
            return paragraph.replacingOccurrences(of: "\n", with: " ")
        }

        /// Every configuration option in the order they're declared.
        static let all: [ConfigOption] = (0..<ghostty_config_option_count()).compactMap { i in
            var option = ghostty_config_option_s()
            guard ghostty_config_option(i, &option) else { return nil }
            return ConfigOption(option)
        }

        init(
            name: String,
            help: String = "",
            kind: Kind = .string,
            optional: Bool = false,
            repeatable: Bool = false,
            choices: [String] = []
        ) {
            self.name = name
            self.help = help
            self.kind = kind
            self.optional = optional
            self.repeatable = repeatable
            self.choices = choices
        }

        init(_ c: ghostty_config_option_s) {
            self.name = String(cString: c.name)
            self.help = String(cString: c.help)
            self.kind = switch c.kind {
            case GHOSTTY_CONFIG_OPTION_BOOL: .bool
            case GHOSTTY_CONFIG_OPTION_INT: .int
            case GHOSTTY_CONFIG_OPTION_FLOAT: .float
            case GHOSTTY_CONFIG_OPTION_ENUM: .enumeration
            case GHOSTTY_CONFIG_OPTION_FLAGS: .flags
            case GHOSTTY_CONFIG_OPTION_COLOR: .color
            default: .string
            }
            self.optional = c.optional
            self.repeatable = c.repeatable
            self.choices = (0..<Int(c.choices_len)).compactMap { i in
                c.choices[i].map { String(cString: $0) }
            }
        }
    }
}

extension Ghostty.Config {
    /// The paths of the default configuration files in the order they're loaded,
    /// whether or not they exist.
    static var defaultFilePaths: [String] {
        Ghostty.AllocatedString(ghostty_config_default_file_paths()).string
            .split(separator: "\n")
            .map(String.init)
    }

    /// The value of the given option as it would be written in a configuration file,
    /// excluding the key. Repeatable options have one value per line. Unset options
    /// are empty.
    func formattedValue(_ name: String) -> String {
        guard let config else { return "" }
        return Ghostty.AllocatedString(ghostty_config_format_value(
            config,
            name,
            UInt(name.lengthOfBytes(using: .utf8))
        )).string
    }

    /// True if the value of the given option differs from the other configuration.
    func valueChanged(_ name: String, from other: Ghostty.Config) -> Bool {
        guard let config, let other = other.config else { return false }
        return ghostty_config_value_changed(
            config,
            other,
            name,
            UInt(name.lengthOfBytes(using: .utf8))
        )
    }
}
