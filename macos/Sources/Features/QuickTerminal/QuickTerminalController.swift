import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// Controller for the "quick" terminal.
class QuickTerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? { "QuickTerminal" }

    /// The position for the quick terminal.
    let position: QuickTerminalPosition

    /// The current state of the quick terminal
    private(set) var visible: Bool = false

    /// The previously running application when the terminal is shown. This is NEVER Ghostty.
    /// If this is set then when the quick terminal is animated out then we will restore this
    /// application to the front.
    private var previousApp: NSRunningApplication?

    // The active space when the quick terminal was last shown.
    private var previousActiveSpace: CGSSpace?

    /// Cache for per-screen window state.
    let screenStateCache: QuickTerminalScreenStateCache

    /// Non-nil if we have hidden dock state.
    private var hiddenDock: HiddenDock?

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    /// Tracks if we're currently handling a manual resize to prevent recursion
    private var isHandlingResize: Bool = false

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    let restorable: Bool
    private var restorationState: QuickTerminalRestorableState?

    /// The tabs in display order. The selected tab's splits are always shown
    /// through `surfaceTree`.
    @Published private(set) var tabs: [QuickTerminalTab] = []

    /// The tab currently being displayed.
    @Published private(set) var selectedTab: QuickTerminalTab?

    // We remember each tab's focused surface so we can restore it when
    // switching back to that tab.
    override var focusedSurface: Ghostty.SurfaceView? {
        didSet {
            guard let focusedSurface,
                  let selectedTab,
                  selectedTab.surfaceTree.contains(focusedSurface) else { return }
            selectedTab.focusedSurface = focusedSurface
        }
    }

    override var titleOverride: String? {
        didSet { selectedTab?.titleOverride = titleOverride }
    }

    override var allSurfaces: [Ghostty.SurfaceView] {
        // The tab that owns `surfaceTree` may not have recorded the latest
        // change to it yet, so we use `surfaceTree` in place of its splits.
        let visibleTab = tab(owning: surfaceTree)
        return Array(surfaceTree) + tabs
            .filter { $0 !== visibleTab }
            .flatMap(\.surfaceTree)
    }

    init(_ ghostty: Ghostty.App,
         position: QuickTerminalPosition = .top,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         restorationState: QuickTerminalRestorableState? = nil,
    ) {
        self.position = position
        self.derivedConfig = DerivedConfig(ghostty.config)
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        restorable = (base?.command ?? "") == ""
        self.restorationState = restorationState
        self.screenStateCache = QuickTerminalScreenStateCache(stateByDisplay: restorationState?.screenStateEntries ?? [:])
        // Important detail here: we initialize with an empty surface tree so
        // that we don't start a terminal process. This gets started when the
        // first terminal is shown in `animateIn`.
        super.init(ghostty, baseConfig: base, surfaceTree: .init())

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen(notification:)),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(closeWindow(_:)),
            name: .ghosttyCloseWindow,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseBackgroundSurface),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)

        // Make sure we restore our hidden dock
        hiddenDock = nil
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window = self.window else { return }

        // The controller is the window delegate so we can detect events such as
        // window close so we can animate out.
        window.delegate = self

        // The quick window is restored by `screenStateCache`.
        // We disable this for better control
        window.isRestorable = false

        // Setup our configured appearance that we support.
        syncAppearance()

        // Setup our initial size based on our configured position
        position.setLoaded(window, size: derivedConfig.quickTerminalSize)

        // Upon first adding this Window to its host view, older SwiftUI
        // seems to have a "hiccup" and corrupts the frameRect,
        // sometimes setting the size to zero, sometimes corrupting it.
        // We pass the actual window's frame as "initial" frame directly
        // to the window, so it can use that instead of the frameworks
        // "interpretation"
        if let qtWindow = window as? QuickTerminalWindow {
            qtWindow.initialFrame = window.frame
        }

        // Setup our content
        window.contentView = TerminalViewContainer {
            VStack(spacing: 0) {
                QuickTerminalTabBar(ghostty: ghostty, controller: self)
                TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
            }
        }

        // Clear out our frame at this point, the fixup from above is complete.
        if let qtWindow = window as? QuickTerminalWindow {
            qtWindow.initialFrame = nil
        }

        // Animate the window in
        animateIn()
    }

    // MARK: NSWindowDelegate

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)

        // If we're not visible we don't care to run the logic below. It only
        // applies if we can be seen.
        guard visible else { return }

        // Re-hide the dock if we were hiding it before.
        hiddenDock?.hide()
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)

        // If we're not visible then we don't want to run any of the logic below
        // because things like resetting our previous app assume we're visible.
        // windowDidResignKey will also get called after animateOut so this
        // ensures we don't run logic twice.
        guard visible else { return }

        // We don't animate out if there is a modal sheet being shown currently.
        // This lets us show alerts without causing the window to disappear.
        guard window?.attachedSheet == nil else { return }

        // If our app is still active, then it means that we're switching
        // to another window within our app, so we remove the previous app
        // so we don't restore it.
        if NSApp.isActive {
            self.previousApp = nil
        }

        // Regardless of autohide, we always want to bring the dock back
        // when we lose focus.
        hiddenDock?.restore()

        if derivedConfig.quickTerminalAutoHide {
            switch derivedConfig.quickTerminalSpaceBehavior {
            case .remain:
                // If we lose focus on the active space, then we can animate out
                animateOut()

            case .move:
                let currentActiveSpace = CGSSpace.active()
                if previousActiveSpace == currentActiveSpace {
                    // We haven't moved spaces. We lost focus to another app on the
                    // current space. Animate out.
                    animateOut()
                } else {
                    // We've moved to a different space.

                    // If we're fullscreen, we need to exit fullscreen because the visible
                    // bounds may have changed causing a new behavior.
                    if let fullscreenStyle, fullscreenStyle.isFullscreen {
                        fullscreenStyle.exit()
                        DispatchQueue.main.async {
                            self.onToggleFullscreen()
                        }
                    }

                    // Make the window visible again on this space
                    DispatchQueue.main.async {
                        self.window?.makeKeyAndOrderFront(nil)
                    }

                    self.previousActiveSpace = currentActiveSpace
                }
            }
        }
    }

    override func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window,
              visible,
              !isHandlingResize else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        // Prevent recursive loops
        isHandlingResize = true
        defer { isHandlingResize = false }

        switch position {
        case .top, .bottom, .center:
            // For centered positions (top, bottom, center), we need to recenter the window
            // when it's manually resized to maintain proper positioning
            let newOrigin = position.centeredOrigin(for: window, on: screen)
            window.setFrameOrigin(newOrigin)
        case .left, .right:
            // For side positions, we may need to adjust vertical centering
            let newOrigin = position.verticallyCenteredOrigin(for: window, on: screen)
            window.setFrameOrigin(newOrigin)
        }
    }

    // MARK: Base Controller Overrides

    override func focusSurface(_ view: Ghostty.SurfaceView) {
        if let tab = tabs.first(where: { $0.surfaceTree.contains(view) }) {
            selectTab(tab)
        }

        if visible {
            // If we're visible, we just focus the surface as normal.
            super.focusSurface(view)
            return
        }
        // Check if target surface belongs to this quick terminal
        guard surfaceTree.contains(view) else { return }
        // Set the target surface as focused
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
        }
        // Animation completion handler will handle window/app activation
        animateIn()
    }

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        // Our initial empty tree is set during init. There's nothing to update,
        // and the base implementation would load our window, which animates
        // in and creates tabs before anything asked to show the quick terminal.
        if from.isEmpty && to.isEmpty { return }

        super.surfaceTreeDidChange(from: from, to: to)

        // If our surface tree is nil then the selected tab has no surfaces
        // left. We switch to a neighboring tab or, if it was the last tab,
        // animate the window out. We defer reinitializing the tree to save
        // some memory here.
        if to.isEmpty {
            if let selectedTab, let index = tabs.firstIndex(where: { $0 === selectedTab }) {
                tabs.remove(at: index)
                self.selectedTab = nil
                if !tabs.isEmpty {
                    selectTab(tabs[min(index, tabs.count - 1)])
                    return
                }
            }

            animateOut()
            return
        }

        // Record the new tree on the tab that owns it. Undo and redo can
        // restore a tree belonging to a background tab, or to a tab that was
        // closed, so we show that tab rather than replacing the selected one.
        let previousOwner = tab(owning: from)
        let owner: QuickTerminalTab
        if let existing = tab(owning: to) {
            existing.surfaceTree = to
            owner = existing
        } else {
            owner = QuickTerminalTab(surfaceTree: to)
            insertTab(owner)
        }
        selectTab(owner)

        // If we're not empty (e.g. this isn't the first set) and we're
        // not visible, then we animate in. This allows us to show the quick
        // terminal when things such as undo/redo are done. Switching tabs
        // alone, such as when a tab is closed, doesn't show it.
        if !from.isEmpty && !visible &&
            (owner === previousOwner || undoManager?.isUndoingOrRedoing == true) {
            animateIn()
            return
        }
    }

    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // If this isn't a final leaf then we're dealing with a split closure
        guard case .leaf(let surface) = node else {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // If its the root, we check if the process exited. If it did,
        // then we do empty the tree.
        if surface.processExited {
            surfaceTree = .init()
            return
        }

        // If we have other tabs then closing the last surface in a tab
        // closes the tab.
        if tabs.count > 1, let selectedTab {
            closeTab(selectedTab, withConfirmation: withConfirmation)
            return
        }

        // If its the root then we just animate out. We never actually allow
        // the surface to fully close.
        animateOut()
    }

    override func closeSurface(
        _ view: Ghostty.SurfaceView,
        withConfirmation: Bool = true
    ) {
        guard let tab = tabs.first(where: { $0 !== selectedTab && $0.surfaceTree.contains(view) }),
              let node = tab.surfaceTree.root?.node(view: view) else {
            super.closeSurface(view, withConfirmation: withConfirmation)
            return
        }

        // Confirmation is shown over the terminal, so the tab must be visible.
        if withConfirmation {
            selectTab(tab)
            super.closeSurface(view, withConfirmation: withConfirmation)
            return
        }

        // Otherwise we close the surface in the background, such as when
        // the shell in a background tab exits.
        if tab.surfaceTree.root == node {
            tabs.removeAll { $0 === tab }
        } else {
            tab.surfaceTree = tab.surfaceTree.removing(node)
        }
    }

    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        var config = config ?? Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        return super.newSplit(at: oldView, direction: direction, baseConfig: config)
    }

    // MARK: Methods

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard !visible else { return }
        visible = true

        // Notify the change
        NotificationCenter.default.post(
            name: .quickTerminalDidChangeVisibility,
            object: self
        )

        // If we have a previously focused application and it isn't us, then
        // we want to store it so we can restore state later.
        if !NSApp.isActive {
            if let previousApp = NSWorkspace.shared.frontmostApplication,
               previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = previousApp
            }
        }

        // Set previous active space
        self.previousActiveSpace = CGSSpace.active()

        // If we have no tabs then we initialize a new terminal. We can have no
        // tabs if for example we run "exit" in the last terminal and force
        // animate out.
        if tabs.isEmpty {
            if let restorationState {
                for saved in restorationState.tabs where !saved.surfaceTree.isEmpty {
                    insertTab(QuickTerminalTab(
                        surfaceTree: saved.surfaceTree,
                        focusedSurface: saved.surfaceTree.first { $0.id.uuidString == saved.focusedSurface },
                        titleOverride: saved.titleOverride
                    ), at: tabs.count)
                }
            }

            if let tab = tabs[safe: restorationState?.selectedTab ?? 0] ?? tabs.first {
                selectTab(tab)
                if let view = tab.focusedSurface {
                    // Add a short delay to check if the correct surface is focused.
                    // Each SurfaceWrapper defaults its FocusedValue to itself; without this delay,
                    // the tree often focuses the first surface instead of the intended one.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if !view.focused {
                            self.focusedSurface = view
                            self.makeWindowKey(window)
                        }
                    }
                }
            } else if let tab = makeTab() {
                insertTab(tab)
                selectTab(tab)
            }
        }

        // Animate the window in
        animateWindowIn(window: window, from: position)
        // Clear the restoration state after first use
        restorationState = nil
    }

    func animateOut() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard visible else { return }
        visible = false

        // Notify the change
        NotificationCenter.default.post(
            name: .quickTerminalDidChangeVisibility,
            object: self
        )

        animateWindowOut(window: window, to: position)
    }

    func saveScreenState(exitFullscreen: Bool) {
        // If we are in fullscreen, then we exit fullscreen. We do this immediately so
        // we have th correct window.frame for the save state below.
        if exitFullscreen, let fullscreenStyle, fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        }
        guard let window else { return }
        // Save the current window frame before animating out. This preserves
        // the user's preferred window size and position for when the quick
        // terminal is reactivated with a new surface. Without this, SwiftUI
        // would reset the window to its minimum content size.
        if window.frame.width > 0 && window.frame.height > 0, let screen = window.screen {
            screenStateCache.save(frame: window.frame, for: screen)
        }
    }

    private func animateWindowIn(window: NSWindow, from position: QuickTerminalPosition) {
        guard let screen = derivedConfig.quickTerminalScreen.screen else { return }

        // Grab our last closed frame to use from the cache.
        let closedFrame = screenStateCache.frame(for: screen)

        // Move our window off screen to the initial animation position.
        position.setInitial(
            in: window,
            on: screen,
            terminalSize: derivedConfig.quickTerminalSize,
            closedFrame: closedFrame)

        // We need to set our window level to a high value. In testing, only
        // popUpMenu and above do what we want. This gets it above the menu bar
        // and lets us render off screen.
        window.level = .popUpMenu

        // Move it to the visible position since animation requires this
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }

        // If our dock position would conflict with our target location then
        // we autohide the dock.
        if position.conflictsWithDock(on: screen) {
            if hiddenDock == nil {
                hiddenDock = .init()
            }

            hiddenDock?.hide()
        } else {
            // Ensure we don't have any hidden dock if we don't conflict.
            // The deinit will restore.
            hiddenDock = nil
        }

        // Run the animation that moves our window into the proper place and makes
        // it visible.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = derivedConfig.quickTerminalAnimationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(
                in: window.animator(),
                on: screen,
                terminalSize: derivedConfig.quickTerminalSize,
                closedFrame: closedFrame)
        }, completionHandler: {
            // There is a very minor delay here so waiting at least an event loop tick
            // keeps us safe from the view not being on the window.
            DispatchQueue.main.async {
                // If we canceled our animation clean up some state.
                guard self.visible else {
                    self.hiddenDock = nil
                    return
                }

                // After animating in, we reset the window level to a value that
                // is above other windows but not as high as popUpMenu. This allows
                // things like IME dropdowns to appear properly.
                window.level = .floating

                // Now that the window is visible, sync our appearance. This function
                // requires the window is visible.
                self.syncAppearance()

                // Once our animation is done, we must grab focus since we can't grab
                // focus of a non-visible window.
                self.makeWindowKey(window)

                // If our application is not active, then we grab focus. Its important
                // we do this AFTER our window is animated in and focused because
                // otherwise macOS will bring forward another window.
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)

                    // This works around a really funky bug where if the terminal is
                    // shown on a screen that has no other Ghostty windows, it takes
                    // a few (variable) event loop ticks until we can actually focus it.
                    // https://github.com/ghostty-org/ghostty/issues/2409
                    //
                    // We wait one event loop tick to try it because under the happy
                    // path (we have windows on this screen) it takes one event loop
                    // tick for window.isKeyWindow to return true.
                    DispatchQueue.main.async {
                        guard !window.isKeyWindow else { return }
                        self.makeWindowKey(window, retries: 10)
                    }
                }
            }
        })
    }

    /// Attempt to make a window key, supporting retries if necessary. The retries will be attempted
    /// on a separate event loop tick.
    ///
    /// The window must contain the focused surface for this terminal controller.
    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        // We must be visible
        guard visible else { return }

        // If our focused view is somehow not connected to this window then the
        // function calls below do nothing. I don't think this is possible but
        // we should guard against it because it is a Cocoa assertion.
        guard let focusedSurface, focusedSurface.window == window else { return }

        // The window must become top-level
        window.makeKeyAndOrderFront(nil)

        // The view must gain our keyboard focus
        window.makeFirstResponder(focusedSurface)

        // If our window is already key then we're done!
        guard !window.isKeyWindow else { return }

        // If we don't have retries then we're done
        guard retries > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
            self.makeWindowKey(window, retries: retries - 1)
        }
    }

    private func animateWindowOut(window: NSWindow, to position: QuickTerminalPosition) {
        saveScreenState(exitFullscreen: true)

        // If we hid the dock then we unhide it.
        hiddenDock = nil

        // If the window isn't on our active space then we don't animate, we just
        // hide it.
        if !window.isOnActiveSpace {
            self.previousApp = nil
            window.orderOut(self)
            // If our application is hidden previously, we hide it again
            if (NSApp.delegate as? AppDelegate)?.hiddenState != nil {
                NSApp.hide(nil)
            }
            return
        }

        // We always animate out to whatever screen the window is actually on.
        guard let screen = window.screen ?? NSScreen.main else { return }

        // If we have a previously active application, restore focus to it. We
        // do this BEFORE the animation below because when the animation completes
        // macOS will bring forward another window.
        if let previousApp = self.previousApp {
            // Make sure we unset the state no matter what
            self.previousApp = nil

            if !previousApp.isTerminated {
                // Ignore the result, it doesn't change our behavior.
                _ = previousApp.activate(options: [])
            }
        }

        // We need to set our window level to a high value. In testing, only
        // popUpMenu and above do what we want. This gets it above the menu bar
        // and lets us render off screen.
        window.level = .popUpMenu

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = derivedConfig.quickTerminalAnimationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(
                in: window.animator(),
                on: screen,
                terminalSize: derivedConfig.quickTerminalSize,
                closedFrame: window.frame)
        }, completionHandler: {
            // This causes the window to be removed from the screen list and macOS
            // handles what should be focused next.
            window.orderOut(self)
            // If our application is hidden previously, we hide it again
            if (NSApp.delegate as? AppDelegate)?.hiddenState != nil {
                NSApp.hide(nil)
            }
        })
    }

    override func syncAppearance() {
        guard let window else { return }

        defer { updateColorSchemeForSurfaceTree() }
        // Change the collection behavior of the window depending on the configuration.
        window.collectionBehavior = derivedConfig.quickTerminalSpaceBehavior.collectionBehavior

        // If our window is not visible, then no need to sync the appearance yet.
        // Some APIs such as window blur have no effect unless the window is visible.
        guard window.isVisible else { return }

        // If we have window transparency then set it transparent. Otherwise set it opaque.
        // Also check if the user has overridden transparency to be fully opaque.
        if !isBackgroundOpaque && (self.derivedConfig.backgroundOpacity < 1 || derivedConfig.backgroundBlur.isGlassStyle) {
            window.isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            window.backgroundColor = .white.withAlphaComponent(0.001)

            if !derivedConfig.backgroundBlur.isGlassStyle {
                ghostty_set_window_background_blur(ghostty.app, Unmanaged.passUnretained(window).toOpaque())
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }

        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: nil)
    }

    override func confirmCloseAsync(messageText: String, informativeText: String, confirmButtonTitle: String = "Close") async -> NSApplication.ModalResponse? {

        let waitTime = visible ? 0 : 0.25
        animateIn()

        try? await Task.sleep(for: .seconds(waitTime))

        return await super.confirmCloseAsync(messageText: messageText, informativeText: informativeText, confirmButtonTitle: confirmButtonTitle)
    }

    // MARK: Tabs

    /// The tab whose splits contain any of the surfaces in the given tree.
    /// An empty tree is owned by the selected tab, since that's the tab whose
    /// last surface was just closed.
    private func tab(owning tree: SplitTree<Ghostty.SurfaceView>) -> QuickTerminalTab? {
        if tree.isEmpty { return selectedTab }
        return tabs.first { tab in tree.contains { tab.surfaceTree.contains($0) } }
    }

    private var selectedTabIndex: Int? {
        tabs.firstIndex { $0 === selectedTab }
    }

    /// Inserts a tab without selecting it. The default position is after the
    /// selected tab, or at the end if `window-new-tab-position` is `end`.
    private func insertTab(_ tab: QuickTerminalTab, at index: Int? = nil) {
        let defaultIndex = if ghostty.config.windowNewTabPosition == "end" {
            tabs.count
        } else {
            selectedTabIndex.map { $0 + 1 } ?? tabs.count
        }
        tabs.insert(tab, at: min(index ?? defaultIndex, tabs.count))
    }

    /// Show the given tab, moving focus to the surface last focused in it.
    func selectTab(_ tab: QuickTerminalTab) {
        guard tab !== selectedTab, tabs.contains(where: { $0 === tab }) else { return }

        selectedTab = tab
        titleOverride = tab.titleOverride

        // The tree is already shown if this tab adopted the current tree.
        if surfaceTree.root != tab.surfaceTree.root {
            surfaceTree = tab.surfaceTree
        }

        // Setting this also unfocuses the surfaces in the previous tab.
        focusedSurface = tab.focusedSurface
        if let focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusedSurface)
            }
        }
    }

    /// Create a tab containing a single new terminal.
    private func makeTab(baseConfig: Ghostty.SurfaceConfiguration? = nil) -> QuickTerminalTab? {
        guard let ghostty_app = ghostty.app else { return nil }
        var config = baseConfig ?? Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        let view = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        return QuickTerminalTab(surfaceTree: SplitTree(view: view))
    }

    /// Open and select a new tab.
    func newTab(withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?) {
        guard let tab = makeTab(baseConfig: baseConfig) else { return }
        insertTab(tab)
        selectTab(tab)

        guard let undoManager else { return }
        undoManager.setActionName("New Tab")
        undoManager.registerUndo(
            withTarget: tab,
            expiresAfter: undoExpiration
        ) { [weak self] tab in
            guard let self else { return }
            undoManager.disableUndoRegistration {
                self.closeTab(tab)
            }

            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                target.newTab(withBaseConfig: baseConfig)
            }
        }
    }

    /// Close a tab, asking for confirmation if it has a running process.
    /// Closing the only tab hides the quick terminal, like closing its window.
    func closeTab(_ tab: QuickTerminalTab, withConfirmation: Bool = true) {
        guard tabs.count > 1 else {
            animateOut()
            return
        }

        guard withConfirmation, tab.surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            removeTab(tab)
            return
        }

        // Show the tab so that it's clear which one the confirmation is for.
        selectTab(tab)
        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) { [weak self] in
            self?.removeTab(tab)
        }
    }

    func closeOtherTabs(_ tab: QuickTerminalTab) {
        closeTabs(
            tabs.filter { $0 !== tab },
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed.",
            undoActionName: "Close Other Tabs")
    }

    func closeTabsOnTheRight(_ tab: QuickTerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTabs(
            Array(tabs[(index + 1)...]),
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed.",
            undoActionName: "Close Tabs to the Right")
    }

    private func closeTabs(
        _ tabsToClose: [QuickTerminalTab],
        messageText: String,
        informativeText: String,
        undoActionName: String
    ) {
        guard !tabsToClose.isEmpty else { return }

        let close = { [weak self] in
            guard let self else { return }
            undoManager?.beginUndoGrouping()
            tabsToClose.forEach(removeTab)
            undoManager?.setActionName(undoActionName)
            undoManager?.endUndoGrouping()
        }

        guard tabsToClose.contains(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) }) else {
            close()
            return
        }

        confirmClose(messageText: messageText, informativeText: informativeText, completion: close)
    }

    /// Remove a tab without confirmation. This registers an undo that
    /// restores the tab, along with its running terminals.
    private func removeTab(_ tab: QuickTerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasSelected = tab === selectedTab

        if let undoManager {
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                target.insertTab(tab, at: index)
                if wasSelected {
                    target.selectTab(tab)
                }

                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.removeTab(tab)
                }
            }
        }

        tabs.remove(at: index)
        guard wasSelected else { return }

        // These surfaces are no longer ours, so moving focus to the next tab
        // won't unfocus them.
        tab.surfaceTree.forEach { $0.focusDidChange(false) }
        selectedTab = nil
        if tabs.isEmpty {
            surfaceTree = .init()
        } else {
            selectTab(tabs[min(index, tabs.count - 1)])
        }
    }

    /// Move a tab into a new terminal window. Returns false if there's no
    /// other tab to keep in the quick terminal.
    @discardableResult
    func moveTabToNewWindow(_ tab: QuickTerminalTab) -> Bool {
        guard tabs.count > 1, tabs.contains(where: { $0 === tab }) else { return false }

        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        removeTab(tab)
        _ = TerminalController.newWindow(
            ghostty,
            tree: tab.surfaceTree,
            confirmUndo: false,
            inheritBackgroundOpacity: isBackgroundOpaque)
        undoManager?.setActionName("Move Tab to New Window")
        return true
    }

    func promptTabTitle(_ tab: QuickTerminalTab) {
        selectTab(tab)
        promptTabTitle()
    }

    // MARK: First Responder

    @IBAction override func closeWindow(_ sender: Any) {
        // Instead of closing the window, we animate it out.
        animateOut()
    }

    @IBAction func newTab(_ sender: Any?) {
        // Going through libghostty lets the new tab inherit from the focused
        // surface, such as its working directory.
        if let surface = focusedSurface?.surface {
            ghostty.newTab(surface: surface)
        } else {
            newTab(withBaseConfig: nil)
        }
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard let selectedTab else { return }
        closeTab(selectedTab)
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: Notifications

    @objc private func applicationWillTerminate(_ notification: Notification) {
        // If the application is going to terminate we want to make sure we
        // restore any global dock state. I think deinit should be called which
        // would call this anyways but I can't be sure so I will do this too.
        hiddenDock = nil
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        onToggleFullscreen()
    }

    private func onToggleFullscreen() {
        // We ignore the configured fullscreen style and always use non-native
        // because the way the quick terminal works doesn't support native.
        let mode: FullscreenMode
        if NSApp.isFrontmost {
            // If we're frontmost and we have a notch then we keep padding
            // so all lines of the terminal are visible.
            if window?.screen?.hasNotch ?? false {
                mode = .nonNativePaddedNotch
            } else {
                mode = .nonNative
            }
        } else {
            // An additional detail is that if the is NOT frontmost, then our
            // NSApp.presentationOptions will not take effect so we must always
            // do the visible menu mode since we can't get rid of the menu.
            mode = .nonNativeVisibleMenu
        }

        toggleFullscreen(mode: mode)
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)

        syncAppearance()

        terminalViewContainer?.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
    }

    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }

        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        newTab(withBaseConfig: configAny as? Ghostty.SurfaceConfiguration)
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        guard let tabEnum = notification.userInfo?[Ghostty.Notification.GotoTabKey] as? ghostty_action_goto_tab_e else { return }
        guard let selectedIndex = selectedTabIndex else { return }

        let finalIndex: Int
        switch tabEnum {
        case GHOSTTY_GOTO_TAB_PREVIOUS:
            finalIndex = (selectedIndex - 1 + tabs.count) % tabs.count
        case GHOSTTY_GOTO_TAB_NEXT:
            finalIndex = (selectedIndex + 1) % tabs.count
        case GHOSTTY_GOTO_TAB_LAST:
            finalIndex = tabs.count - 1
        default:
            // Other values are 1-indexed tab positions.
            let tabIndex = Int(tabEnum.rawValue)
            guard tabIndex >= 1 else { return }
            finalIndex = min(tabIndex - 1, tabs.count - 1)
        }

        selectTab(tabs[finalIndex])
    }

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard let selectedIndex = selectedTabIndex else { return }

        // Moves are clamped to the ends rather than wrapping around.
        let finalIndex = max(0, min(tabs.count - 1, selectedIndex + action.amount))
        guard finalIndex != selectedIndex else { return }

        var newTabs = tabs
        newTabs.insert(newTabs.remove(at: selectedIndex), at: finalIndex)
        tabs = newTabs
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target), let selectedTab else { return }
        closeTab(selectedTab)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target), let selectedTab else { return }
        closeOtherTabs(selectedTab)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target), let selectedTab else { return }
        closeTabsOnTheRight(selectedTab)
    }

    @objc private func onCloseBackgroundSurface(notification: SwiftUI.Notification) {
        // The base controller handles surfaces in the selected tab.
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard tabs.contains(where: { $0 !== selectedTab && $0.surfaceTree.contains(target) }) else { return }

        // We wait a tick so that, if the tab must be selected for a
        // confirmation, the base controller doesn't also handle this
        // notification once the surface is in the selected tab.
        let withConfirmation = (notification.userInfo?["process_alive"] as? Bool) ?? false
        DispatchQueue.main.async {
            self.closeSurface(target, withConfirmation: withConfirmation)
        }
    }

    private struct DerivedConfig {
        let quickTerminalScreen: QuickTerminalScreen
        let quickTerminalAnimationDuration: Double
        let quickTerminalAutoHide: Bool
        let quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior
        let quickTerminalSize: QuickTerminalSize
        let backgroundOpacity: Double
        let backgroundBlur: Ghostty.Config.BackgroundBlur

        init() {
            self.quickTerminalScreen = .main
            self.quickTerminalAnimationDuration = 0.2
            self.quickTerminalAutoHide = true
            self.quickTerminalSpaceBehavior = .move
            self.quickTerminalSize = QuickTerminalSize()
            self.backgroundOpacity = 1.0
            self.backgroundBlur = .disabled
        }

        init(_ config: Ghostty.Config) {
            self.quickTerminalScreen = config.quickTerminalScreen
            self.quickTerminalAnimationDuration = config.quickTerminalAnimationDuration
            self.quickTerminalAutoHide = config.quickTerminalAutoHide
            self.quickTerminalSpaceBehavior = config.quickTerminalSpaceBehavior
            self.quickTerminalSize = config.quickTerminalSize
            self.backgroundOpacity = config.backgroundOpacity
            self.backgroundBlur = config.backgroundBlur
        }
    }

    /// Hides the dock globally (not just NSApp). This is only used if the quick terminal is
    /// in a conflicting position with the dock.
    private class HiddenDock {
        let previousAutoHide: Bool
        private var hidden: Bool = false

        init() {
            previousAutoHide = Dock.autoHideEnabled
        }

        deinit {
            restore()
        }

        func hide() {
            guard !hidden else { return }
            NSApp.acquirePresentationOption(.autoHideDock)
            Dock.autoHideEnabled = true
            hidden = true
        }

        func restore() {
            guard hidden else { return }
            NSApp.releasePresentationOption(.autoHideDock)
            Dock.autoHideEnabled = previousAutoHide
            hidden = false
        }
    }
}

extension Notification.Name {
    /// The quick terminal did become hidden or visible.
    static let quickTerminalDidChangeVisibility = Notification.Name("QuickTerminalDidChangeVisibility")
}
