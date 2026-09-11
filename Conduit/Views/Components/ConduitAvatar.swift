import SwiftUI

/// One avatar entry point for Ink surfaces: brand mark, character, or group stack.
struct ConduitAvatar: View {
    var size: CGFloat
    var animates: Bool = false
    private let kind: Kind

    private enum Kind {
        case bot(MessagingProfile, photoURL: URL?, state: AgentAvatarState)
        case group([MessagingProfile], photoURL: (MessagingProfile) -> URL?)
    }

    static func bot(
        _ profile: MessagingProfile,
        photoURL: URL?,
        state: AgentAvatarState = .idle,
        size: CGFloat,
        animates: Bool = false
    ) -> ConduitAvatar {
        ConduitAvatar(
            size: size,
            animates: animates,
            kind: .bot(profile, photoURL: photoURL, state: state)
        )
    }

    static func group(
        _ members: [MessagingProfile],
        photoURL: @escaping (MessagingProfile) -> URL?,
        size: CGFloat,
        animates: Bool = false
    ) -> ConduitAvatar {
        ConduitAvatar(
            size: size,
            animates: animates,
            kind: .group(members, photoURL: photoURL)
        )
    }

    var body: some View {
        switch kind {
        case .bot(let profile, let photoURL, let state):
            if ConduitAvatarIdentity.usesBrandMark(displayName: profile.displayName, name: profile.name) {
                BrandMarkAvatar(size: size)
            } else {
                AgentAvatar(
                    profileID: profile.name,
                    displayName: profile.displayName,
                    photoURL: photoURL,
                    size: size,
                    state: state,
                    animates: animates
                )
            }
        case .group(let members, let photoURL):
            GroupStackAvatar(
                members: members,
                size: size,
                photoURL: photoURL,
                animates: animates
            )
        }
    }
}

enum ConduitAvatarIdentity {
    static func usesBrandMark(displayName: String, name: String) -> Bool {
        displayName.localizedCaseInsensitiveContains("penelope")
            || name.localizedCaseInsensitiveContains("penelope")
    }
}
