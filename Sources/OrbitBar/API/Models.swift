import Foundation

// Records of Orbit's internal API (`/api/v1`), the one the web and mobile apps use.
// Field names arrive in snake_case and are converted by the decoder.

struct User: Codable, Equatable, Sendable {
    var id: String
    var email: String
    var displayName: String
    var avatarUrl: String?
}

struct Workspace: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var role: String
    var deletedAt: String?
}

struct Project: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var key: String
    var color: String
    var deletedAt: String?
}

struct TaskStatus: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var projectId: String
    var name: String
    var color: String
    /// `unstarted`, `started`, `completed`, `cancelled` or `duplicate`.
    var category: String
    var position: Int

    var isDone: Bool { StatusCategory.done.contains(category) }
}

enum StatusCategory {
    static let done: Set<String> = ["completed", "cancelled", "duplicate"]

    /// The order of the list's sections.
    static func rank(_ category: String) -> Int {
        switch category {
        case "started": return 0
        case "unstarted": return 1
        case "completed": return 2
        case "cancelled": return 3
        case "duplicate": return 4
        default: return 5
        }
    }

    /// A menu icon for a status category (menus draw icons in one color).
    static func symbol(_ category: String) -> String {
        switch category {
        case "started": return "circle.lefthalf.filled"
        case "completed": return "checkmark.circle.fill"
        case "cancelled": return "xmark.circle"
        case "duplicate": return "plus.square.on.square"
        default: return "circle"
        }
    }

    static func title(_ category: String) -> String {
        switch category {
        case "started": return "In Progress"
        case "unstarted": return "To Do"
        case "completed": return "Done"
        case "cancelled": return "Cancelled"
        case "duplicate": return "Duplicate"
        default: return category.capitalized
        }
    }
}

struct Member: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var userId: String
    var email: String
    var displayName: String
    var avatarUrl: String?
    var suspendedAt: String?
}

struct OrbitTask: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var workspaceId: String
    var projectId: String
    var statusId: String
    var number: Int
    var title: String
    var description: String
    var priority: String
    var position: Int
    var assigneeIds: [String]
    var labelIds: [String]
    var dueAt: String?
    var dueStartAt: String?
    var parentTaskId: String?
    var creatorId: String?
    var version: Int
    var createdAt: String
    var updatedAt: String
}

extension OrbitTask {
    /// The same task with another version: a local change shown on top of a server copy.
    init(copying task: OrbitTask, version: Int) {
        self = task
        self.version = version
    }
}

enum Priority: String, CaseIterable, Identifiable, Sendable {
    case none, low, medium, high, urgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "No priority"
        default: return rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .none: return "minus"
        case .low: return "chart.bar.fill"
        case .medium: return "chart.bar.fill"
        case .high: return "chart.bar.fill"
        case .urgent: return "exclamationmark.square.fill"
        }
    }

    /// The icon in menus: signal bars filled to the priority, as Orbit draws it.
    var menuSymbol: (name: String, fill: Double?) {
        switch self {
        case .none: return ("minus", nil)
        case .low: return ("cellularbars", 0.34)
        case .medium: return ("cellularbars", 0.67)
        case .high: return ("cellularbars", 1)
        case .urgent: return ("exclamationmark.square.fill", nil)
        }
    }

    /// Lower sorts first: urgent → none.
    var rank: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .none: return 4
        }
    }

    var next: Priority {
        let all = Priority.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct PageOf<T: Decodable & Sendable>: Decodable, Sendable {
    var items: [T]
    var nextCursor: String?
}

/// Every answer of the sign-in endpoints: a session (200), the second-factor step or the
/// password step of a first provider link (202).
struct SignInAnswer: Decodable, Sendable {
    var sessionToken: String?
    var user: User?
    var twoFactorToken: String?
    var passwordToken: String?
    var provider: String?
    var email: String?
}

struct AuthOptions: Decodable, Sendable {
    var providers: [String]
    var oidcName: String?
    var version: String?
}

struct ProviderStart: Decodable, Sendable {
    var authorizeUrl: String
}

/// RFC 9457 problem document with Orbit's `code`.
struct Problem: Decodable, Sendable {
    var status: Int?
    var code: String?
    var title: String?
    var detail: String?
}

enum OrbitDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    static func format(_ date: Date) -> String { fractional.string(from: date) }

    /// A day picked in the UI becomes the end of that local day, as the web's quick due dates do.
    static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
    }
}
