import SwiftUI
import GhosttyKit

extension Ghostty {
    /// An annotation (iTerm2 OSC 1337 AddAnnotation) to show over a surface.
    struct Annotation: Equatable {
        enum Kind {
            /// Shown while the mouse is over the annotated cells.
            case hover

            /// Shown when the annotation is added, until dismissed.
            case reveal
        }

        let message: String
        let kind: Kind

        /// The start of the annotated cells on the anchor row, in surface
        /// coordinates with a top-left origin.
        let anchor: CGRect

        init(message: String, kind: Kind, anchor: CGRect) {
            self.message = message
            self.kind = kind
            self.anchor = anchor
        }

        init?(_ v: ghostty_action_annotation_s) {
            guard let ptr = v.message else { return nil }
            let message = String(cString: ptr)
            guard !message.isEmpty else { return nil }
            self.message = message
            self.kind = v.kind == GHOSTTY_ANNOTATION_REVEAL ? .reveal : .hover
            self.anchor = CGRect(
                x: CGFloat(v.x),
                y: CGFloat(v.y),
                width: 0,
                height: CGFloat(v.height)
            )
        }
    }

    /// Positions an annotation bubble next to its anchor, below it if it fits
    /// and above it otherwise.
    struct SurfaceAnnotationOverlay: View {
        let annotation: Annotation
        let onClose: () -> Void

        @State private var bubbleSize: CGSize = .zero

        private let gap: CGFloat = 4
        private let margin: CGFloat = 6
        private let maxWidth: CGFloat = 360

        var body: some View {
            GeometryReader { geo in
                SurfaceAnnotationBubble(annotation: annotation, onClose: onClose)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { size in
                        bubbleSize = size
                    }
                    .frame(
                        maxWidth: min(maxWidth, max(geo.size.width - margin * 2, 0)),
                        alignment: .topLeading
                    )
                    .offset(offset(in: geo.size))
                    .opacity(bubbleSize == .zero ? 0 : 1)
            }
            .allowsHitTesting(annotation.kind == .reveal)
        }

        private func offset(in container: CGSize) -> CGSize {
            let anchor = annotation.anchor

            let maxX = max(container.width - bubbleSize.width - margin, margin)
            let x = min(max(anchor.minX, margin), maxX)

            let below = anchor.maxY + gap
            let above = anchor.minY - gap - bubbleSize.height
            let y = below + bubbleSize.height <= container.height - margin || above < margin
                ? below
                : above

            return CGSize(width: x, height: y)
        }
    }

    private struct SurfaceAnnotationBubble: View {
        let annotation: Annotation
        let onClose: () -> Void

        private let cornerRadius: CGFloat = 8

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.yellow)
                    .frame(width: 3)

                Text(verbatim: annotation.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if annotation.kind == .reveal {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }
}
