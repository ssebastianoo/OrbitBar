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

/// The order of the tasks inside each section of the list.
enum TaskSort: String, CaseIterable, Identifiable, Sendable {
    case newest, updated, priority, due, oldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest First"
        case .updated: return "Recently Updated"
        case .priority: return "Priority"
        case .due: return "Due Date"
        case .oldest: return "Oldest First"
        }
    }

    /// `true` when `a` comes before `b`. Ties fall back to the newest task first.
    nonisolated func inOrder(_ a: OrbitTask, _ b: OrbitTask) -> Bool {
        func date(_ s: String?) -> Date { OrbitDate.parse(s) ?? .distantPast }
        func newer() -> Bool {
            let ca = date(a.createdAt), cb = date(b.createdAt)
            return ca != cb ? ca > cb : a.number > b.number
        }
        switch self {
        case .newest:
            return newer()
        case .oldest:
            let ca = date(a.createdAt), cb = date(b.createdAt)
            return ca != cb ? ca < cb : a.number < b.number
        case .updated:
            let ua = date(a.updatedAt), ub = date(b.updatedAt)
            return ua != ub ? ua > ub : newer()
        case .priority:
            let pa = (Priority(rawValue: a.priority) ?? .none).rank, pb = (Priority(rawValue: b.priority) ?? .none).rank
            if pa != pb { return pa < pb }
            let da = OrbitDate.parse(a.dueAt) ?? .distantFuture, db = OrbitDate.parse(b.dueAt) ?? .distantFuture
            return da != db ? da < db : newer()
        case .due:
            let da = OrbitDate.parse(a.dueAt) ?? .distantFuture, db = OrbitDate.parse(b.dueAt) ?? .distantFuture
            return da != db ? da < db : newer()
        }
    }
}

/// A status in the list's status filter. Statuses belong to projects, so the filter merges the ones with the
/// same name ("Todo" of every project is one entry).
struct StatusOption: Identifiable, Equatable, Sendable {
    /// The lowercased name.
    var id: String
    var name: String
    var category: String
    var position: Int
    /// One of the merged statuses, for its icon and color.
    var sample: TaskStatus

    nonisolated static func key(_ status: TaskStatus) -> String {
        status.name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The statuses shown before the person picks: everything but backlog and finished ones.
    nonisolated static func visibleByDefault(_ status: TaskStatus) -> Bool {
        !status.isDone && key(status) != "backlog"
    }

    /// Whether tasks with this status are shown, given the person's saved choices (lowercased name → shown).
    nonisolated static func isVisible(_ status: TaskStatus, choices: [String: Bool]) -> Bool {
        choices[key(status)] ?? visibleByDefault(status)
    }

    /// One entry per status name, in the list's section order.
    nonisolated static func merge(_ statuses: [TaskStatus]) -> [StatusOption] {
        var byKey: [String: StatusOption] = [:]
        for status in statuses {
            let key = key(status)
            if let existing = byKey[key], StatusCategory.rank(existing.category) < StatusCategory.rank(status.category)
                || (existing.category == status.category && existing.position <= status.position) { continue }
            byKey[key] = StatusOption(id: key, name: status.name, category: status.category, position: status.position, sample: status)
        }
        return byKey.values.sorted(by: inOrder)
    }

    nonisolated static func inOrder(_ a: StatusOption, _ b: StatusOption) -> Bool {
        let ra = StatusCategory.rank(a.category), rb = StatusCategory.rank(b.category)
        if ra != rb { return ra < rb }
        if a.position != b.position { return a.position < b.position }
        return a.id < b.id
    }
}
