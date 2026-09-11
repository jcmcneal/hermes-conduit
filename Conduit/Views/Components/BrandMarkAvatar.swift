import SwiftUI

/// Circular crop of the Penelope app mark on the Ink canvas disc.
struct BrandMarkAvatar: View, Equatable {
    var size: CGFloat
    var assetName: String = "AppIconPreview"

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .background(Color.conduitCanvas)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
