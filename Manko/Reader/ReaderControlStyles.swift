import SwiftUI

struct ReaderGlassCapsuleStyle: ViewModifier {
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(interactive), in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        }
    }
}

private struct ReaderOverlayPanel: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}

extension View {
    func readerOverlayPanel() -> some View {
        modifier(ReaderOverlayPanel())
    }
}

struct ReaderGlassCircleStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        }
    }
}
