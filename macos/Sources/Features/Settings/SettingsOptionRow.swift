import AppKit
import SwiftUI

/// A single configuration option: its name, documentation, and a control to
/// edit it. Expanding the row shows the full documentation and, for
/// repeatable options, an editor for each value.
///
/// Rows don't observe the model so that a change to one option only updates
/// its own row; the state is passed in and compared instead.
struct SettingsOptionRow: View, Equatable {
    let model: SettingsModel
    let option: Ghostty.ConfigOption
    let state: SettingsModel.OptionState
    let errors: [String]

    @State private var expanded = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.option.name == rhs.option.name
            && lhs.state == rhs.state
            && lhs.errors == rhs.errors
    }

    private var supported: Bool {
        SettingsCategory.isSupportedOnMacOS(option.name)
    }

    /// Options that have no effect on macOS are greyed out.
    private var dimming: Double {
        supported ? 1 : 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    summary
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                Group {
                    if option.repeatable {
                        Text(state.values.isEmpty ? "None" : "^[\(state.values.count) value](inflect: true)")
                            .foregroundStyle(.secondary)
                    } else {
                        SettingsControl(model: model, option: option, state: state)
                    }
                }
                .opacity(dimming)

                Button {
                    model.reset(option)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reset to the default by removing it from the config file")
                .opacity(state.isSet ? 1 : 0)
                .disabled(!state.isSet)
            }

            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if expanded {
                details
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.name)
                        .font(.system(.body, design: .monospaced))
                        .opacity(dimming)
                    modifiedIndicator
                    if !supported {
                        Text("GTK only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().strokeBorder(.tertiary))
                            .help("This option only has an effect in the GTK app on Linux and FreeBSD")
                    }
                }

                if !option.summary.isEmpty && !expanded {
                    Text(SettingsFormat.markdown(option.summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .opacity(dimming)
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var modifiedIndicator: some View {
        if state.isSet {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .help("Set in \(state.sources.map { SettingsFormat.abbreviatedPath($0.file) }.joined(separator: ", "))")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if option.repeatable {
                SettingsRepeatableEditor(model: model, option: option, state: state)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(SettingsFormat.paragraphs(option.help).enumerated()), id: \.offset) { _, paragraph in
                    Text(SettingsFormat.markdown(paragraph))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                if !option.repeatable {
                    GridRow {
                        Text("Default").foregroundStyle(.secondary)
                        Text(state.defaultValues.first.map { $0.isEmpty ? "(empty)" : $0 } ?? "(not set)")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if !state.sources.isEmpty {
                    GridRow {
                        Text("Set in").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            ForEach(state.sources, id: \.file) { source in
                                Text(SettingsFormat.abbreviatedPath(source.file))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else if state.changed {
                    GridRow {
                        Text("Set by").foregroundStyle(.secondary)
                        Text("A theme, a command-line argument, or another option")
                    }
                }
            }
            .font(.callout)
        }
        .padding(.leading, 18)
    }
}

/// The editing control for a single-valued option.
private struct SettingsControl: View {
    let model: SettingsModel
    let option: Ghostty.ConfigOption
    let state: SettingsModel.OptionState

    var body: some View {
        switch option.kind {
        case .bool where !option.optional:
            Toggle("", isOn: Binding(
                get: { state.value == "true" },
                set: { model.set(option, to: $0 ? "true" : "false") }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

        case .bool:
            choicePicker(["true", "false"])

        case .enumeration:
            choicePicker(option.choices)

        case .flags:
            SettingsFlagsMenu(model: model, option: option, state: state)

        case .color:
            SettingsColorControl(model: model, option: option, state: state)

        case .int, .float:
            textField(width: 110)

        case .string:
            textField(width: 240)
        }
    }

    private var placeholder: String {
        if let value = state.defaultValues.first, !value.isEmpty { return value }
        return option.optional ? "Not set" : ""
    }

    private func textField(width: CGFloat) -> some View {
        SettingsTextField(value: state.fileValue, placeholder: placeholder, width: width) {
            model.set(option, to: $0)
        }
    }

    private func choicePicker(_ choices: [String]) -> some View {
        // Include the current value in case it's an alias we don't know about.
        let all = choices.contains(state.value) || state.value.isEmpty ? choices : choices + [state.value]

        return Picker("", selection: Binding(
            get: { state.value },
            set: { model.set(option, to: $0) }
        )) {
            if option.optional {
                Text("Default").tag("")
                Divider()
            }

            ForEach(all, id: \.self) { choice in
                Text(choice).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// A menu of checkable flags for options like `shell-integration-features`.
private struct SettingsFlagsMenu: View {
    let model: SettingsModel
    let option: Ghostty.ConfigOption
    let state: SettingsModel.OptionState

    var body: some View {
        let enabled = Set(state.value.split(separator: ",").map(String.init).filter { !$0.hasPrefix("no-") })

        Menu {
            ForEach(option.choices, id: \.self) { flag in
                Toggle(flag, isOn: Binding(
                    get: { enabled.contains(flag) },
                    set: { on in
                        var updated = enabled
                        if on { updated.insert(flag) } else { updated.remove(flag) }
                        let value = option.choices
                            .map { updated.contains($0) ? $0 : "no-\($0)" }
                            .joined(separator: ",")
                        model.set(option, to: value)
                    }
                ))
            }
        } label: {
            let names = option.choices.filter { enabled.contains($0) }
            Text(names.isEmpty ? "None" : names.joined(separator: ", "))
        }
        .fixedSize()
    }
}

/// A color well paired with a text field for values that aren't plain colors,
/// such as `cell-foreground`.
private struct SettingsColorControl: View {
    let model: SettingsModel
    let option: Ghostty.ConfigOption
    let state: SettingsModel.OptionState

    @State private var color: Color = .clear

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .opacity(NSColor(hex: state.value) == nil ? 0.35 : 1)
                .onChange(of: color) { newValue in
                    // Only write when the color differs from the config so that
                    // syncing the picker to the config never writes the file.
                    guard let hex = Self.hex(newValue), hex != Self.hex(Self.color(state.value)) else { return }
                    model.setDebounced(option, to: hex)
                }

            SettingsTextField(
                value: state.fileValue,
                placeholder: option.optional ? "Not set" : "",
                width: 130
            ) {
                model.set(option, to: $0)
            }
        }
        .onAppear { sync() }
        .onChange(of: state.value) { _ in sync() }
    }

    private func sync() {
        // While a change from the color panel is pending, the config still has
        // an older color and syncing would snap the panel back to it.
        guard !model.isPending(option) else { return }
        color = Self.color(state.value)
    }

    private static func color(_ value: String) -> Color {
        NSColor(hex: value).map { Color(nsColor: $0) } ?? .clear
    }

    private static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        guard rgb.alphaComponent > 0 else { return nil }
        return String(
            format: "#%02x%02x%02x",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}

/// Edits the values of a repeatable option in each file that sets it.
private struct SettingsRepeatableEditor: View {
    let model: SettingsModel
    let option: Ghostty.ConfigOption
    let state: SettingsModel.OptionState

    @State private var showEffective = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Values are edited where they're defined. New values go to the last
            // file that sets the option, or the main config file.
            let sources = state.sources.isEmpty
                ? [SettingsModel.Source(file: model.mainFile, values: [])]
                : state.sources

            ForEach(sources, id: \.file) { source in
                VStack(alignment: .leading, spacing: 4) {
                    if sources.count > 1 || source.file != model.mainFile {
                        Text(SettingsFormat.abbreviatedPath(source.file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsListEditor(
                        values: source.values,
                        allowsAdding: source.file == sources.last?.file
                    ) {
                        model.set(option, values: $0, in: source.file)
                    }
                }
            }

            let fileValues = state.sources.flatMap(\.values)
            if !state.values.isEmpty && state.values != fileValues {
                DisclosureGroup(isExpanded: $showEffective) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.values.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                } label: {
                    Text("Effective values, including defaults (\(state.values.count))")
                        .font(.callout)
                }
            }
        }
    }
}

/// An editable list of values with add and remove buttons.
private struct SettingsListEditor: View {
    let values: [String]
    let allowsAdding: Bool
    let onChange: ([String]) -> Void

    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(spacing: 6) {
                    SettingsTextField(value: value, placeholder: "", width: nil) { updated in
                        var values = values
                        values[index] = updated
                        onChange(values)
                    }

                    Button {
                        var values = values
                        values.remove(at: index)
                        onChange(values)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this value")
                }
            }

            if allowsAdding {
                HStack(spacing: 6) {
                    TextField("", text: $newValue, prompt: Text("Add a value"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .onSubmit(add)

                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(newValue.isEmpty)
                    .help("Add this value")
                }
            }
        }
    }

    private func add() {
        guard !newValue.isEmpty else { return }
        onChange(values + [newValue])
        newValue = ""
    }
}

/// A text field that commits its value when Return is pressed or it loses focus,
/// so we don't write the config file on every keystroke.
struct SettingsTextField: View {
    let value: String
    let placeholder: String
    let width: CGFloat?
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { focused in
                if !focused { commit() }
            }
            .onChange(of: value) { text = $0 }
            .onAppear { text = value }
    }

    private func commit() {
        guard text != value else { return }
        onCommit(text)
    }
}
