import SwiftUI

/// The settings window: every configuration option, grouped by category,
/// searchable, and editable. Edits are written to the config files.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    @State private var selection: SettingsModel.Selection?
    @State private var query: String

    init(model: SettingsModel, selection: SettingsModel.Selection = .all, query: String = "") {
        self.model = model
        self._selection = State(initialValue: selection)
        self._query = State(initialValue: query)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            SettingsDetailView(model: model, selection: selection ?? .all, query: query)
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("All Settings", systemImage: "slider.horizontal.3")
                    .tag(SettingsModel.Selection.all)
                Label("Modified", systemImage: "pencil.circle")
                    .badge(model.modifiedCount)
                    .tag(SettingsModel.Selection.modified)
            }

            Section("Categories") {
                ForEach(model.categories) { category in
                    Label(category.title, systemImage: category.symbol)
                        .foregroundStyle(model.gtkOnlyCategories.contains(category) ? .secondary : .primary)
                        .tag(SettingsModel.Selection.category(category))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            SettingsSearchField(text: $query, placeholder: "Search")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .modifier(HiddenSidebarToggle())
    }
}

private struct SettingsDetailView: View {
    @ObservedObject var model: SettingsModel
    let selection: SettingsModel.Selection
    let query: String

    var body: some View {
        let groups = model.groups(for: selection, matching: query)
        let count = groups.reduce(0) { $0 + $1.options.count }

        VStack(spacing: 0) {
            header(count: count)

            if let error = model.writeError {
                banner(Text(error), systemImage: "xmark.octagon.fill", color: .red)
            }

            if !model.errors.isEmpty {
                banner(
                    Text("""
                        ^[\(model.errors.count) configuration error](inflect: true) found. \
                        Invalid values are ignored until they're fixed.
                        """),
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }

            if groups.isEmpty {
                emptyState
            } else {
                // A grouped Form lays out every row up front, which is slow
                // with hundreds of options, so this mimics one lazily.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(Array(group.options.enumerated()), id: \.element.id) { index, option in
                                    SettingsOptionRow(
                                        model: model,
                                        option: option,
                                        state: model.state(for: option),
                                        errors: model.errors(for: option)
                                    )
                                    .equatable()
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(SettingsGroupBackground(
                                        first: index == 0,
                                        last: index == group.options.count - 1
                                    ))
                                }
                            } header: {
                                if showsSectionHeaders {
                                    Text(group.category.title)
                                        .font(.headline)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 18)
                                        .padding(.bottom, 8)
                                } else {
                                    Spacer().frame(height: 12)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }

            Divider()
            footer
        }
    }

    private var title: String {
        if !query.isEmpty { return "Search Results" }
        return switch selection {
        case .all: "All Settings"
        case .modified: "Modified"
        case .category(let category): category.title
        }
    }

    private var showsSectionHeaders: Bool {
        if !query.isEmpty { return true }
        if case .category = selection { return false }
        return true
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text("^[\(count) option](inflect: true)")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func banner(_ text: Text, systemImage: String, color: Color) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: selection == .modified && query.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(selection == .modified && query.isEmpty
                 ? "No options are set in your config files."
                 : "No options match \u{201C}\(query)\u{201D}.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(SettingsFormat.abbreviatedPath(model.mainFile))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(model.files.map(\.path).joined(separator: "\n"))

            if model.files.count > 1 {
                Text("and ^[\(model.files.count - 1) other file](inflect: true)")
                    .foregroundStyle(.secondary)
                    .help(model.files.map(\.path).joined(separator: "\n"))
            }

            Spacer()

            Button("Open in Editor") { model.openInEditor() }
            Button("Reload") { model.reload() }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The background of a row in a group of rows, rounding the group's outer
/// corners and separating it from the row above.
private struct SettingsGroupBackground: View {
    let first: Bool
    let last: Bool

    private let radius: CGFloat = 8

    var body: some View {
        // Extend the rounded rectangle past the edges that join another row
        // and clip it so only the group's outer corners are rounded.
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .padding(.top, first ? 0 : -radius)
            .padding(.bottom, last ? 0 : -radius)
            .clipped()
            .overlay(alignment: .top) {
                if !first {
                    Divider().padding(.horizontal, 10)
                }
            }
    }
}

/// Like System Settings, the sidebar can't be collapsed.
private struct HiddenSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// A native search field.
private struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

enum SettingsFormat {
    static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Split help text into paragraphs, unwrapping hard-wrapped lines while
    /// keeping list items on their own lines. Fenced and indented paragraphs
    /// are code.
    static func paragraphs(_ help: String) -> [String] {
        help.components(separatedBy: "\n\n").compactMap { paragraph in
            var lines = paragraph.split(separator: "\n")
            guard !lines.isEmpty else { return nil }

            let fenced = lines.count >= 2 && lines.first!.hasPrefix("```") && lines.last!.hasPrefix("```")
            if fenced || lines.allSatisfy({ $0.hasPrefix("    ") }) {
                if fenced { lines = Array(lines.dropFirst().dropLast()) }
                return lines.map { line in
                    let code = line.trimmingCharacters(in: .whitespaces)
                    return code.contains("`") ? code : "`\(code)`"
                }.joined(separator: "\n")
            }

            var result = ""
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                    if !result.isEmpty { result += "\n" }
                    result += "•" + trimmed.dropFirst()
                } else {
                    result += result.isEmpty ? trimmed : " " + trimmed
                }
            }

            return result
        }
    }

    /// Render inline Markdown such as `code` and *emphasis*.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
