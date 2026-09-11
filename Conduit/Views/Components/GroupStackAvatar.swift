import SwiftUI

/// Overlapping bot faces with a `+N` badge. Static — no TimelineView.
struct GroupStackAvatar: View {
    let members: [MessagingProfile]
    var size: CGFloat
    var photoURL: (MessagingProfile) -> URL?
    var animates: Bool = false
    var visibleLimit: Int = GroupStackOverflow.visibleLimit

    private var visibleMembers: [MessagingProfile] {
        Array(members.prefix(visibleLimit))
    }

    private var overflowLabel: String? {
        GroupStackOverflow.badge(memberCount: members.count, visibleLimit: visibleLimit)
    }

    var body: some View {
        let face = max(18, size * 0.64)
        let overlap = face * 0.34
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: -overlap) {
                ForEach(visibleMembers) { profile in
                    stackFace(profile, size: face)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.conduitCanvas, lineWidth: max(2, face * 0.055))
                        }
                }
            }

            if let overflowLabel {
                Text(overflowLabel)
                    .font(.system(size: max(9, size * 0.14), weight: .semibold))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .padding(.horizontal, max(4, size * 0.06))
                    .frame(minWidth: size * 0.28, minHeight: size * 0.28)
                    .background(Color.conduitRaisedSurface, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.conduitCanvas, lineWidth: max(1.5, size * 0.03))
                    }
                    .offset(x: size * 0.02, y: size * 0.02)
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stackFace(_ profile: MessagingProfile, size: CGFloat) -> some View {
        if ConduitAvatarIdentity.usesBrandMark(displayName: profile.displayName, name: profile.name) {
            BrandMarkAvatar(size: size)
        } else {
            AgentAvatar(
                profileID: profile.name,
                displayName: profile.displayName,
                photoURL: photoURL(profile),
                size: size,
                animates: animates
            )
        }
    }
}
