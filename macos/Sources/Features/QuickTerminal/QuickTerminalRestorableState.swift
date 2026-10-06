import Cocoa

struct QuickTerminalRestorableState: TerminalRestorable {
    static var version: Int { 2 }
    static var minimumVersion: Int { 1 }

    typealias Tab = InternalState<Ghostty.SurfaceView>.Tab

    /// The tabs in display order.
    var tabs: [Tab] {
        internalState.allTabs
    }

    /// The index of the selected tab within `tabs`.
    var selectedTab: Int {
        internalState.selectedTab ?? 0
    }

    var screenStateEntries: QuickTerminalScreenStateCache.Entries {
        internalState.screenStateEntries
    }

    private let internalState: InternalState<Ghostty.SurfaceView>

    init(from controller: QuickTerminalController) {
        controller.saveScreenState(exitFullscreen: true)
        self.internalState = .init(from: controller)
    }

    init(copy other: QuickTerminalRestorableState) {
        self = other
    }

    var baseConfig: Ghostty.SurfaceConfiguration? {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        return config
    }
}

extension QuickTerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `QuickTerminalRestorableState`
    /// due to `CodableBridge<QuickTerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 1 (1.3.0)

        /// Only used by version 1, which had a single tab. Newer versions
        /// leave this empty and store the splits in `tabs` instead.
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>
        let screenStateEntries: QuickTerminalScreenStateCache.Entries

        // MARK: - Version 2

        let tabs: [Tab]?
        let selectedTab: Int?

        struct Tab: Codable {
            let focusedSurface: String?
            let surfaceTree: SplitTree<ViewType>
            let titleOverride: String?
        }

        /// The saved tabs, including the single tab saved by version 1.
        var allTabs: [Tab] {
            tabs ?? [.init(focusedSurface: focusedSurface, surfaceTree: surfaceTree, titleOverride: nil)]
        }
    }
}

extension QuickTerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: QuickTerminalController) {
        self.init(
            focusedSurface: nil,
            surfaceTree: .init(),
            screenStateEntries: controller.screenStateCache.stateByDisplay,
            tabs: controller.tabs.map { tab in
                .init(
                    focusedSurface: tab.focusedSurface?.id.uuidString,
                    surfaceTree: tab.surfaceTree,
                    titleOverride: tab.titleOverride)
            },
            selectedTab: controller.tabs.firstIndex { $0 === controller.selectedTab },
        )
    }
}
