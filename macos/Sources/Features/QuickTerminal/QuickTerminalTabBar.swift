import SwiftUI

/// The tab bar for the quick terminal. This is only shown when there is more
/// than one tab.
struct QuickTerminalTabBar: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: QuickTerminalController

    var body: some View {
        if controller.tabs.count > 1 {
            let tabs = controller.tabs
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    if index > 0 {
                        // Separators are hidden next to the selected tab, which
                        // stands out on its own.
                        separator(visible: tab !== controller.selectedTab &&
                                  tabs[index - 1] !== controller.selectedTab)
                    }

                    QuickTerminalTabItem(
                        tab: tab,
                        isSelected: tab === controller.selectedTab,
                        isLast: index == tabs.count - 1,
                        shortcut: index < 9 ? ghostty.config.keyboardShortcut(for: "goto_tab:\(index + 1)") : nil,
                        showsBell: ghostty.config.bellFeatures.contains(.title),
                        style: style,
                        controller: controller)
                }

                separator(visible: tabs.last !== controller.selectedTab)

                QuickTerminalNewTabButton(style: style) {
                    controller.newTab(nil)
                }
            }
            .frame(height: 28)
            .environment(\.colorScheme, style.isLight ? .light : .dark)
        }
    }

    private var style: QuickTerminalTabBarStyle {
        .init(
            backgroundColor: ghostty.config.backgroundColor,
            backgroundOpacity: ghostty.config.backgroundOpacity)
    }

    private func separator(visible: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(visible ? 0.15 : 0))
            .frame(width: 1)
            .padding(.vertical, 7)
            .background { style.background(selected: false, hovered: false) }
    }
}

/// The colors of the tab bar, which are derived from the terminal background
/// so that the selected tab blends into the terminal below it.
private struct QuickTerminalTabBarStyle {
    let backgroundColor: Color
    let backgroundOpacity: Double

    var isLight: Bool {
        NSColor(backgroundColor).isLightColor
    }

    func background(selected: Bool, hovered: Bool) -> some View {
        // Unselected tabs are darkened, less so when hovered.
        let shade: Double = switch (selected, hovered) {
        case (true, _): 0
        case (false, true): isLight ? 0.04 : 0.15
        case (false, false): isLight ? 0.08 : 0.3
        }

        return backgroundColor
            .opacity(backgroundOpacity)
            .overlay { Color.black.opacity(shade) }
    }
}

private struct QuickTerminalTabItem: View {
    @ObservedObject var tab: QuickTerminalTab
    let isSelected: Bool
    let isLast: Bool
    let shortcut: KeyboardShortcut?
    let showsBell: Bool
    let style: QuickTerminalTabBarStyle
    let controller: QuickTerminalController

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        ZStack {
            Button {
                controller.selectTab(tab)
            } label: {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            HStack(spacing: 0) {
                closeButton
                Spacer()
                if let shortcut {
                    Text(shortcut.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { style.background(selected: isSelected, hovered: isHovered) }
        .onHover { isHovered = $0 }
        .help(title)
        .contextMenu {
            Button("Close Tab") { controller.closeTab(tab) }
            Button("Close Other Tabs") { controller.closeOtherTabs(tab) }
            Button("Close Tabs to the Right") { controller.closeTabsOnTheRight(tab) }
                .disabled(isLast)
            Divider()
            Button("Change Tab Title...") { controller.promptTabTitle(tab) }
            Button("Move Tab to New Window") { controller.moveTabToNewWindow(tab) }
        }
    }

    private var title: String {
        let title = tab.titleOverride ?? (tab.surfaceTitle.isEmpty ? "👻" : tab.surfaceTitle)
        return tab.bell && showsBell ? "🔔 \(title)" : title
    }

    private var closeButton: some View {
        Button {
            controller.closeTab(tab)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(isCloseHovered ? 0.15 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHovered ? 1 : 0)
        .onHover { isCloseHovered = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
    }
}

private struct QuickTerminalNewTabButton: View {
    let style: QuickTerminalTabBarStyle
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background { style.background(selected: false, hovered: isHovered) }
        .onHover { isHovered = $0 }
        .help("New Tab")
        .accessibilityLabel("New Tab")
    }
}
