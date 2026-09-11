import SwiftUI

struct ConversationRowModel: Equatable {
    var title: String
    var preview: String
    var time: String
    var isPinned: Bool = false
    var isSelected: Bool = false
}

struct ConversationRow<Artwork: View>: View, Equatable {
    let model: ConversationRowModel
    var artworkSize: CGFloat = 0
    private let artwork: Artwork

    init(
        model: ConversationRowModel,
        artworkSize: CGFloat = 0,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.model = model
        self.artworkSize = artworkSize
        self.artwork = artwork()
    }

    static func == (lhs: ConversationRow<Artwork>, rhs: ConversationRow<Artwork>) -> Bool {
        lhs.model == rhs.model && lhs.artworkSize == rhs.artworkSize
    }

    var body: some View {
        HStack(alignment: .center, spacing: artworkSize > 0 ? ConduitInboxMetrics.rowArtworkTextGap : 0) {
            if artworkSize > 0 {
                artwork
                    .frame(width: artworkSize, height: artworkSize)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.conduitPrimaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !model.time.isEmpty {
                        Text(model.time)
                            .font(.caption)
                            .foregroundStyle(Color.conduitSecondaryText)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    if model.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.conduitSecondaryText)
                            .accessibilityHidden(true)
                    }
                    if !model.preview.isEmpty {
                        Text(model.preview)
                            .font(.subheadline)
                            .foregroundStyle(Color.conduitSecondaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(minHeight: ConduitInboxMetrics.rowMinimumHeight, alignment: .center)
        .contentShape(Rectangle())
        .background(
            model.isSelected
                ? Color.conduitRaisedSurface.opacity(0.9)
                : Color.clear
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [model.title]
        if model.isPinned { parts.append("Pinned") }
        if !model.preview.isEmpty { parts.append(model.preview) }
        if !model.time.isEmpty { parts.append(model.time) }
        return parts.joined(separator: ", ")
    }
}

extension ConversationRow where Artwork == EmptyView {
    init(
        session: SessionSummary,
        secondaryLine: String,
        isPinned: Bool,
        isSelected: Bool
    ) {
        self.init(
            model: ConversationRowModel(
                title: session.title,
                preview: secondaryLine,
                time: session.updatedLabel,
                isPinned: isPinned,
                isSelected: isSelected
            )
        ) {
            EmptyView()
        }
    }
}

/// Home-row secondary copy: cached activity snippet, else source label — never model.
enum ConversationActivityCopy {
    static func secondaryLine(
        session: SessionSummary,
        cachedSnippet: String?,
        liveMessages: [ChatMessage]? = nil
    ) -> String {
        if let live = SessionPresentationCache.activityPreview(from: liveMessages ?? []), !live.isEmpty {
            return live
        }
        if let cached = cachedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return cached
        }
        return session.source.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
