import SwiftUI

/// 86pt pin cell: artwork + 12pt caption, two-line cap. Equality ignores artwork.
struct PinnedShelfCell<Artwork: View>: View, Equatable {
    let title: String
    let size: CGFloat
    private let artwork: Artwork

    init(title: String, size: CGFloat, @ViewBuilder artwork: () -> Artwork) {
        self.title = title
        self.size = size
        self.artwork = artwork()
    }

    static func == (lhs: PinnedShelfCell<Artwork>, rhs: PinnedShelfCell<Artwork>) -> Bool {
        lhs.title == rhs.title && lhs.size == rhs.size
    }

    var body: some View {
        VStack(spacing: 8) {
            artwork
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.conduitPrimaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size + 8)
        }
    }
}
