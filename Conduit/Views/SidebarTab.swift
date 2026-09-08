import Foundation

/// Persisted sidebar destinations. The raw-value migration is explicit so an
/// obsolete Capabilities value can never leave the sidebar without a valid tab.
/// Display titles use Chats / Scheduled / Boards; raw values stay Sessions /
/// Cron / Kanban for persistence compatibility.
enum SidebarTab: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case cron = "Cron"
    case kanban = "Kanban"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "Chats"
        case .cron: return "Scheduled"
        case .kanban: return "Boards"
        }
    }

    var icon: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .cron: return "clock"
        case .kanban: return "rectangle.3.group"
        }
    }

    static func migrated(rawValue: String?) -> SidebarTab {
        guard let rawValue, let value = SidebarTab(rawValue: rawValue) else {
            return .sessions
        }
        return value
    }
}
