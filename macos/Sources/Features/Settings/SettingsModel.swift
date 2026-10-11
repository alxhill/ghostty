import AppKit
import Combine
import GhosttyKit

/// Backs the settings window. This combines the option descriptions from
/// libghostty with the effective configuration and the config files that set
/// each option, and writes edits back to those files.
class SettingsModel: ObservableObject {
    struct OptionState: Equatable {
        /// The effective values, one per occurrence for repeatable options.
        var values: [String] = []

        var defaultValues: [String] = []

        /// True if the effective value differs from the default.
        var changed = false

        /// The values from each config file that sets the option, in load order.
        var sources: [Source] = []

        /// The effective value of a single-valued option.
        var value: String { values.first ?? "" }

        /// The value as written in the config file that takes effect, falling
        /// back to the effective value. This differs from `value` when the file
        /// has an invalid value or uses an alternate spelling.
        var fileValue: String { sources.last?.values.last ?? value }

        var isSet: Bool { !sources.isEmpty }
    }

    struct Source: Equatable {
        let file: URL
        let values: [String]
    }

    enum Selection: Hashable {
        case all
        case modified
        case category(SettingsCategory)
    }

    struct Group: Identifiable {
        let category: SettingsCategory
        let options: [Ghostty.ConfigOption]
        var id: SettingsCategory { category }
    }

    let options: [Ghostty.ConfigOption]

    /// The categories that contain at least one option, in display order.
    let categories: [SettingsCategory]

    /// The categories whose options all only work with GTK.
    let gtkOnlyCategories: Set<SettingsCategory>

    @Published private(set) var states: [String: OptionState] = [:]

    /// The config files that are loaded, in load order.
    @Published private(set) var files: [URL] = []

    /// The file new options are written to.
    @Published private(set) var mainFile: URL

    @Published private(set) var errors: [String] = []

    /// The last error writing a config file, if any.
    @Published var writeError: String?

    private let ghostty: Ghostty.App
    private let defaults: Ghostty.Config
    private let categoryByOption: [String: SettingsCategory]
    private var pending: [String: DispatchWorkItem] = [:]

    init(ghostty: Ghostty.App, options: [Ghostty.ConfigOption] = Ghostty.ConfigOption.all) {
        self.ghostty = ghostty
        self.options = options
        self.mainFile = URL(fileURLWithPath: ghostty.configFilePath)
        let categoryByOption = Dictionary(uniqueKeysWithValues: options.map {
            ($0.name, SettingsCategory(option: $0.name))
        })
        let used = Set(categoryByOption.values)
        self.categoryByOption = categoryByOption
        self.categories = SettingsCategory.allCases.filter { used.contains($0) }
        let supported = Set(options.filter { SettingsCategory.isSupportedOnMacOS($0.name) }.map {
            categoryByOption[$0.name] ?? .other
        })
        self.gtkOnlyCategories = used.subtracting(supported)

        let defaults = ghostty_config_new()
        if let defaults { ghostty_config_finalize(defaults) }
        self.defaults = Ghostty.Config(config: defaults)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )

        refresh(ghostty.config)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func state(for option: Ghostty.ConfigOption) -> OptionState {
        states[option.name] ?? OptionState()
    }

    func category(for option: Ghostty.ConfigOption) -> SettingsCategory {
        categoryByOption[option.name] ?? .other
    }

    /// The number of options set in a config file.
    var modifiedCount: Int {
        options.filter { state(for: $0).isSet }.count
    }

    /// Configuration errors that mention the option.
    func errors(for option: Ghostty.ConfigOption) -> [String] {
        errors.filter { $0.hasPrefix("\(option.name):") || $0.contains(":\(option.name):") }
    }

    /// The options to show for the selection and search query, grouped by category.
    func groups(for selection: Selection, matching query: String) -> [Group] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let matches = options.filter { option in
            switch selection {
            case .all: break
            case .modified: guard state(for: option).isSet else { return false }
            case .category(let category):
                // Searching looks through everything, like System Settings.
                guard !terms.isEmpty || self.category(for: option) == category else { return false }
            }

            return terms.allSatisfy { term in
                option.name.contains(term) || option.help.lowercased().contains(term)
            }
        }

        // Rank options whose name matches the query ahead of those that only
        // match their documentation.
        let ranked = terms.isEmpty ? matches : matches.filter { option in
            terms.allSatisfy { option.name.contains($0) }
        } + matches.filter { option in
            !terms.allSatisfy { option.name.contains($0) }
        }

        return categories.compactMap { category in
            let options = ranked.filter { self.category(for: $0) == category }
            return options.isEmpty ? nil : Group(category: category, options: options)
        }
    }

    // MARK: Editing

    /// Set a single-valued option. An empty value removes it so the default applies.
    func set(_ option: Ghostty.ConfigOption, to value: String) {
        pending.removeValue(forKey: option.name)?.cancel()
        guard !value.isEmpty else {
            reset(option)
            return
        }

        // Edit the file that currently takes effect so the change isn't
        // overridden by a file loaded later.
        let file = state(for: option).sources.last?.file ?? mainFile
        edit(file) { $0.set(option.name, values: [value]) }
    }

    /// Set a single-valued option after a short delay, coalescing rapid changes
    /// such as dragging in a color picker.
    func setDebounced(_ option: Ghostty.ConfigOption, to value: String) {
        pending[option.name]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.set(option, to: value) }
        pending[option.name] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// True while a debounced change to the option hasn't been written yet.
    func isPending(_ option: Ghostty.ConfigOption) -> Bool {
        pending[option.name] != nil
    }

    /// Replace the values a repeatable option has in one config file.
    func set(_ option: Ghostty.ConfigOption, values: [String], in file: URL) {
        edit(file) { $0.set(option.name, values: values.filter { !$0.isEmpty }) }
    }

    /// Remove the option from every config file so the default applies.
    func reset(_ option: Ghostty.ConfigOption) {
        let files = state(for: option).sources.map(\.file)
        guard !files.isEmpty else { return }
        for file in files {
            edit(file, reload: false) { $0.remove(option.name) }
        }
        reload()
    }

    func reload() {
        ghostty.reloadConfig()
    }

    func openInEditor() {
        ghostty.openConfig()
    }

    private func edit(_ url: URL, reload: Bool = true, _ body: (inout ConfigFile) -> Void) {
        do {
            // Always start from what's on disk so we don't clobber edits made
            // in another editor since we last refreshed.
            var file = try ConfigFile.load(url)
            body(&file)
            try file.write()
            writeError = nil
        } catch {
            writeError = "Unable to write \(url.path): \(error.localizedDescription)"
            return
        }

        if reload { self.reload() }
    }

    // MARK: Refreshing

    @objc private func configDidChange(_ notification: Notification) {
        // Surface-specific configs don't affect the settings.
        guard notification.object == nil else { return }
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }
        refresh(config)
    }

    private func refresh(_ config: Ghostty.Config) {
        let files = loadedFiles(config)
        let parsed: [(URL, [String: [String]])] = files.compactMap { url in
            guard let file = try? ConfigFile.load(url) else { return nil }
            return (url, Dictionary(grouping: file.entries, by: \.key).mapValues { $0.map(\.value) })
        }

        var states: [String: OptionState] = [:]
        for option in options {
            let name = option.name
            states[name] = OptionState(
                values: Self.lines(config.formattedValue(name)),
                defaultValues: Self.lines(defaults.formattedValue(name)),
                changed: config.valueChanged(name, from: defaults),
                sources: parsed.compactMap { url, entries in
                    entries[name].map { Source(file: url, values: $0) }
                }
            )
        }

        self.mainFile = URL(fileURLWithPath: ghostty.configFilePath)
        self.files = files
        self.states = states
        self.errors = config.errors
    }

    /// The config files that the configuration was loaded from, in load order.
    private func loadedFiles(_ config: Ghostty.Config) -> [URL] {
        let base = ghostty.configPath.map { [$0] } ?? Ghostty.Config.defaultFilePaths
        let includes = Self.lines(config.formattedValue("config-file")).map {
            $0.hasPrefix("?") ? String($0.dropFirst()) : $0
        }

        var seen: Set<String> = []
        return (base + includes)
            .filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func lines(_ value: String) -> [String] {
        value.isEmpty ? [] : value.components(separatedBy: "\n")
    }
}
