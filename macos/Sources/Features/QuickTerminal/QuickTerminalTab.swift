import Combine
import Foundation

/// A tab within the quick terminal.
///
/// The quick terminal is a single panel so it can't use native macOS window
/// tabs. Instead, the controller keeps a list of these and displays the
/// selected tab's splits.
final class QuickTerminalTab: ObservableObject, Identifiable {
    let id = UUID()

    /// The splits within this tab. While this tab is selected, this mirrors the
    /// controller's surface tree.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        didSet {
            if let focusedSurface, surfaceTree.contains(focusedSurface) { return }
            focusedSurface = surfaceTree.first
        }
    }

    /// The surface to focus when this tab is selected.
    @Published var focusedSurface: Ghostty.SurfaceView?

    /// A title set by the user that takes precedence over the terminal title.
    @Published var titleOverride: String?

    /// The title of the focused surface.
    @Published private(set) var surfaceTitle: String = ""

    /// True when any surface in this tab has an active bell.
    @Published private(set) var bell: Bool = false

    init(
        surfaceTree: SplitTree<Ghostty.SurfaceView>,
        focusedSurface: Ghostty.SurfaceView? = nil,
        titleOverride: String? = nil
    ) {
        self.surfaceTree = surfaceTree
        self.focusedSurface = focusedSurface ?? surfaceTree.first
        self.titleOverride = titleOverride

        $focusedSurface
            .map { $0?.$title.eraseToAnyPublisher() ?? Just("").eraseToAnyPublisher() }
            .switchToLatest()
            .removeDuplicates()
            .assign(to: &$surfaceTitle)

        $surfaceTree
            .map { $0.valuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell) }
            .switchToLatest()
            .map { $0.values.contains(true) }
            .removeDuplicates()
            .assign(to: &$bell)
    }
}
