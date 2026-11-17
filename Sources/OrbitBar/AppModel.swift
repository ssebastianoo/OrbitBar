import AppKit
import Foundation
import Observation

/// What the editor works on: a new task (no `taskID`) or a copy of an existing one.
struct TaskDraft: Equatable {
    var taskID: String?
    var original: OrbitTask?
    var projectID: String
    var statusID: String
    var title: String = ""
    var description: String = ""
    var priority: Priority = .none
    var assigneeIDs: Set<String> = []
    var hasDue = false
    var due = Date()

    var isNew: Bool { taskID == nil }

    init(newIn projectID: String, statusID: String, assignee: String?) {
        self.projectID = projectID
        self.statusID = statusID
        if let assignee { assigneeIDs = [assignee] }
    }

    init(task: OrbitTask) {
        taskID = task.id
        original = task
        projectID = task.projectId
        statusID = task.statusId
        title = task.title
        description = task.description
        priority = Priority(rawValue: task.priority) ?? .none
        assigneeIDs = Set(task.assigneeIds)
        if let due = OrbitDate.parse(task.dueAt) {
            hasDue = true
            self.due = due
        }
    }

    /// The create body, or for an edit only the fields that changed (plus `expected_version`).
    /// Nil when an edit changes nothing.
    func body() -> JSONBody? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let dueValue: Any = hasDue ? OrbitDate.format(OrbitDate.endOfDay(due)) : NSNull()
        guard let original else {
            var body: JSONBody = [
                "project_id": projectID,
                "status_id": statusID,
                "title": title,
                "description": description,
                "priority": priority.rawValue,
                "assignee_ids": assigneeIDs.sorted(),
            ]
            if hasDue { body["due_at"] = dueValue }
            return body
        }
        var body: JSONBody = [:]
        if title != original.title { body["title"] = title }
        if description != original.description { body["description"] = description }
        if projectID != original.projectId { body["project_id"] = projectID }
        if statusID != original.statusId || projectID != original.projectId { body["status_id"] = statusID }
        if priority.rawValue != original.priority { body["priority"] = priority.rawValue }
        if assigneeIDs != Set(original.assigneeIds) { body["assignee_ids"] = assigneeIDs.sorted() }
        let originalDue = OrbitDate.parse(original.dueAt)
        if hasDue != (originalDue != nil) || (hasDue && !Calendar.current.isDate(due, inSameDayAs: originalDue!)) {
            body["due_at"] = dueValue
            if !hasDue { body["due_start_at"] = NSNull() }
        }
        if body.isEmpty { return nil }
        body["expected_version"] = original.version
        return body
    }
}

struct TaskSection: Identifiable {
    var id: String { category }
    var category: String
    var tasks: [OrbitTask]
}

@MainActor
@Observable
final class AppModel {
    enum Phase { case launching, signedOut, signedIn }
    enum Screen: Equatable { case list, editor, account, help }
    enum SignInStep: Equatable {
        case credentials
        case twoFactor(server: URL, token: String)
        case linkPassword(server: URL, token: String, provider: String, email: String)
    }

    // MARK: Session
    var phase: Phase = .launching
    var signInStep: SignInStep = .credentials
    var serverInput: String = Prefs.server ?? ""
    var authOptions: AuthOptions?
    private(set) var client: OrbitClient?
    var user: User?

    // MARK: Data
    var workspaces: [Workspace] = []
    var workspaceID: String?
    var projects: [Project] = []
    var statusesByProject: [String: [TaskStatus]] = [:]
    var statusByID: [String: TaskStatus] = [:]
    var members: [Member] = []
    var tasks: [OrbitTask] = []

    // MARK: Filters
    var projectFilter: String?
    var onlyMine = Prefs.onlyMine
    var showDone = Prefs.showDone
    var search = ""

    // MARK: UI
    var screen: Screen = .list
    var selectedID: String?
    var draft: TaskDraft?
    var confirmTrash: OrbitTask?
    var isLoading = false
    var isBusy = false
    var errorMessage: String?
    var searchFocusRequest = 0
    var searchFocused = false
    var titleFocusRequest = 0
    var statusPicker: StatusPicker?
    /// Set by the panel controller: gives the keyboard back to the panel after a nested popover closes.
    var refocusPanel: () -> Void = {}
    var editingDescription = false
    var showDuePicker = false
    var saveState: SaveState = .idle
    private var isCommitting = false
    private var commitQueued = false
    private var lastRefresh: Date?
    /// Bumped when a session starts or ends: answers for an older session are dropped.
    private var sessionGeneration = 0
    /// Bumped by each workspace load; a newer one (or a sign-out) makes older results stale.
    private var workspaceGeneration = 0
    /// Bumped by each task load, a workspace switch and a sign-out.
    private var taskGeneration = 0
    /// `perform` calls nest (sign-in → bootstrap → workspace): loading lasts until the outermost ends.
    private var loadingCount = 0
    private let conflictRetriesLimit = 2
    private let providerSignIn = ProviderSignIn()

    /// Set by the panel controller: closes the menu bar panel.
    var closePanel: () -> Void = {}

    // MARK: - Lookups

    var workspace: Workspace? { workspaces.first { $0.id == workspaceID } }
    var filterProject: Project? { projects.first { $0.id == projectFilter } }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    func member(_ userID: String) -> Member? { members.first { $0.userId == userID } }
    func statuses(of projectID: String) -> [TaskStatus] { statusesByProject[projectID] ?? [] }

    func identifier(_ task: OrbitTask) -> String {
        "\(project(task.projectId)?.key ?? "#")-\(task.number)"
    }

    func isDone(_ task: OrbitTask) -> Bool { statusByID[task.statusId]?.isDone ?? false }

    var selectedTask: OrbitTask? { tasks.first { $0.id == selectedID } }

    // MARK: - Visible list

    var sections: [TaskSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = tasks.filter { task in
            if let projectFilter, task.projectId != projectFilter { return false }
            if onlyMine, let me = user?.id, !task.assigneeIds.contains(me) { return false }
            if !showDone, isDone(task) { return false }
            if !query.isEmpty {
                let haystack = "\(identifier(task)) \(task.title)".lowercased()
                if !query.split(separator: " ").allSatisfy({ haystack.contains($0) }) { return false }
            }
            return true
        }
        let grouped = Dictionary(grouping: visible) { statusByID[$0.statusId]?.category ?? "unstarted" }
        return grouped
            .sorted { StatusCategory.rank($0.key) < StatusCategory.rank($1.key) }
            .map { TaskSection(category: $0.key, tasks: $0.value.sorted(by: order)) }
    }

    var visibleTasks: [OrbitTask] { sections.flatMap(\.tasks) }

    private func order(_ a: OrbitTask, _ b: OrbitTask) -> Bool {
        let pa = (Priority(rawValue: a.priority) ?? .none).rank, pb = (Priority(rawValue: b.priority) ?? .none).rank
        if pa != pb { return pa < pb }
        let da = OrbitDate.parse(a.dueAt) ?? .distantFuture, db = OrbitDate.parse(b.dueAt) ?? .distantFuture
        if da != db { return da < db }
        return a.updatedAt > b.updatedAt
    }

    // MARK: - Launch & sign-in

    func launch() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ORBITBAR_DEMO"] != nil { loadDemo(); return }
        #endif
        guard let server = Prefs.server, let url = OrbitClient.normalize(server), let token = Keychain.token(server: url.absoluteString) else {
            phase = .signedOut
            return
        }
        client = OrbitClient(server: url, token: token)
        phase = .signedIn
        Task { await bootstrap() }
    }

    func loadAuthOptions() async {
        guard let url = OrbitClient.normalize(serverInput) else { authOptions = nil; return }
        let typed = serverInput
        let options = try? await OrbitClient(server: url, token: nil).authOptions()
        if typed == serverInput { authOptions = options }
    }

    func signIn(email: String, password: String) async {
        guard let url = OrbitClient.normalize(serverInput) else { errorMessage = OrbitError.invalidServer.errorDescription; return }
        await perform {
            let answer = try await OrbitClient(server: url, token: nil).login(email: email, password: password)
            try await self.handle(answer, server: url)
        }
    }

    func submitSecondFactor(_ code: String) async {
        guard case .twoFactor(let url, let token) = signInStep else { return }
        await perform {
            let answer = try await OrbitClient(server: url, token: nil).loginSecondFactor(token: token, code: code.trimmingCharacters(in: .whitespaces))
            try await self.handle(answer, server: url)
        }
    }

    func signIn(provider: String) async {
        guard let url = OrbitClient.normalize(serverInput) else { errorMessage = OrbitError.invalidServer.errorDescription; return }
        await perform {
            guard let answer = try await self.providerSignIn.run(client: OrbitClient(server: url, token: nil), provider: provider) else { return }
            try await self.handle(answer, server: url)
        }
    }

    func linkProvider(password: String) async {
        guard case .linkPassword(let url, let token, _, _) = signInStep else { return }
        await perform {
            let answer = try await OrbitClient(server: url, token: nil).linkProvider(passwordToken: token, password: password)
            try await self.handle(answer, server: url)
        }
    }

    func cancelSignInStep() {
        signInStep = .credentials
        errorMessage = nil
    }

    private func handle(_ answer: SignInAnswer, server: URL) async throws {
        if let token = answer.twoFactorToken {
            signInStep = .twoFactor(server: server, token: token)
        } else if let token = answer.passwordToken {
            signInStep = .linkPassword(server: server, token: token, provider: answer.provider ?? "", email: answer.email ?? "")
        } else if let token = answer.sessionToken {
            let saved = Keychain.save(token: token, server: server.absoluteString)
            // Signing in to another server replaces the old session: don't leave its token behind.
            if let previous = Prefs.server, previous != server.absoluteString { Keychain.delete(server: previous) }
            if let old = client, old.server.absoluteString != server.absoluteString { Keychain.delete(server: old.server.absoluteString) }
            Prefs.server = server.absoluteString
            serverInput = server.absoluteString
            client = OrbitClient(server: server, token: token)
            user = answer.user
            signInStep = .credentials
            phase = .signedIn
            screen = .list
            sessionGeneration += 1
            await bootstrap()
            if !saved, errorMessage == nil {
                errorMessage = "Signed in, but the keychain refused to store the session: you'll have to sign in again after OrbitBar quits."
            }
        } else {
            throw OrbitError.unexpected("The server did not return a session token. Update the Orbit server.")
        }
    }

    func signOut() async {
        if let client { try? await client.logout() }
        forgetSession()
    }

    private func forgetSession() {
        if let client { Keychain.delete(server: client.server.absoluteString) }
        // Results of calls still running for this session must not land after it is gone.
        sessionGeneration += 1
        workspaceGeneration += 1
        taskGeneration += 1
        writeChains.values.forEach { $0.cancel() }
        writeChains = [:]
        selectedID = nil
        confirmTrash = nil
        statusPicker = nil
        lastRefresh = nil
        client = nil
        user = nil
        workspaces = []
        workspaceID = nil
        projects = []
        statusesByProject = [:]
        statusByID = [:]
        members = []
        tasks = []
        draft = nil
        screen = .list
        signInStep = .credentials
        phase = .signedOut
    }

    // MARK: - Loading

    private func bootstrap() async {
        guard let client else { return }
        let generation = sessionGeneration
        await perform {
            async let me = client.me()
            async let list = client.workspaces()
            let (user, workspaces) = try await (me, list)
            guard generation == self.sessionGeneration else { return }
            self.user = user
            self.workspaces = workspaces
            let preferred = Prefs.workspaceID.flatMap { id in workspaces.first { $0.id == id } } ?? workspaces.first
            if let preferred { await self.selectWorkspace(preferred.id) }
        }
    }

    func selectWorkspace(_ id: String) async {
        guard let client else { return }
        workspaceID = id
        Prefs.workspaceID = id
        projectFilter = Prefs.projectFilter(workspace: id)
        projects = []
        tasks = []
        selectedID = nil
        workspaceGeneration += 1
        taskGeneration += 1  // a task load for the previous workspace must not land here
        let generation = workspaceGeneration
        await perform {
            async let projectsCall = client.projects(id)
            async let membersCall = client.members(id)
            let (projects, members) = try await (projectsCall, membersCall)
            let statuses = try await withThrowingTaskGroup(of: (String, [TaskStatus]).self) { group in
                for project in projects {
                    group.addTask { (project.id, try await client.statuses(id, projectID: project.id)) }
                }
                var result: [String: [TaskStatus]] = [:]
                for try await (projectID, list) in group { result[projectID] = list.sorted { $0.position < $1.position } }
                return result
            }
            guard generation == self.workspaceGeneration else { return }
            self.projects = projects
            self.members = members.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            self.statusesByProject = statuses
            self.statusByID = Dictionary(uniqueKeysWithValues: statuses.values.flatMap { $0 }.map { ($0.id, $0) })
            if let filter = self.projectFilter, !projects.contains(where: { $0.id == filter }) { self.projectFilter = nil }
        }
        guard generation == workspaceGeneration else { return }
        await reloadTasks()
    }

    func reloadTasks() async {
        guard let client, let workspaceID else { return }
        taskGeneration += 1
        let generation = taskGeneration
        await perform(showsLoading: true) {
            let list = try await client.tasks(workspaceID, projectID: self.projectFilter, view: self.onlyMine ? "mine" : nil)
            guard generation == self.taskGeneration, workspaceID == self.workspaceID else { return }
            // Keep local copies that are newer than this page (a write finished while it loaded).
            let local = Dictionary(self.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.tasks = list.map { fetched in
                guard let mine = local[fetched.id], mine.version > fetched.version else { return fetched }
                return mine
            }
            self.lastRefresh = Date()
            self.keepSelectionValid()
        }
    }

    func refresh() async {
        guard let workspaceID else { await bootstrap(); return }
        await selectWorkspace(workspaceID)
    }

    /// Called when the panel opens: refreshes quietly when the data is older than 30 seconds.
    func panelDidOpen() {
        guard phase == .signedIn else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        Task { await reloadTasks() }
    }

    /// Runs a call, shows its error, and signs out when the session has ended.
    private func perform(showsLoading: Bool = true, _ work: @escaping () async throws -> Void) async {
        if showsLoading { loadingCount += 1; isLoading = true }
        errorMessage = nil
        defer {
            if showsLoading {
                loadingCount -= 1
                isLoading = loadingCount > 0
            }
        }
        do {
            try await work()
        } catch OrbitError.unauthorized {
            forgetSession()
            errorMessage = OrbitError.unauthorized.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Filters

    func setProjectFilter(_ id: String?) {
        guard id != projectFilter else { return }
        projectFilter = id
        if let workspaceID { Prefs.setProjectFilter(id, workspace: workspaceID) }
        Task { await reloadTasks() }
    }

    func cycleProjectFilter(_ step: Int) {
        let options: [String?] = [nil] + projects.map(\.id)
        let index = options.firstIndex(of: projectFilter) ?? 0
        setProjectFilter(options[(index + step + options.count) % options.count])
    }

    func cycleWorkspace(_ step: Int) {
        guard !workspaces.isEmpty else { return }
        let index = workspaces.firstIndex { $0.id == workspaceID } ?? 0
        let next = workspaces[(index + step + workspaces.count) % workspaces.count]
        Task { await selectWorkspace(next.id) }
    }

    func setOnlyMine(_ value: Bool) {
        guard value != onlyMine else { return }
        onlyMine = value
        Prefs.onlyMine = value
        Task { await reloadTasks() }
    }

    func setShowDone(_ value: Bool) {
        showDone = value
        Prefs.showDone = value
        keepSelectionValid()
    }

    // MARK: - Selection

    func keepSelectionValid() {
        let visible = visibleTasks
        if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
        selectedID = visible.first?.id
    }

    func moveSelection(_ step: Int) {
        let visible = visibleTasks
        guard !visible.isEmpty else { selectedID = nil; return }
        guard let current = visible.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = step >= 0 ? visible.first?.id : visible.last?.id
            return
        }
        selectedID = visible[min(max(current + step, 0), visible.count - 1)].id
    }

    // MARK: - Task page

    enum SaveState: Equatable { case idle, saving, saved, failed }

    func newTask() {
        guard phase == .signedIn else { return }
        let projectID = projectFilter
            ?? Prefs.lastProjectForNew.flatMap { id in projects.first { $0.id == id }?.id }
            ?? projects.first?.id
        guard let projectID else { errorMessage = "Create a project in Orbit first."; return }
        draft = TaskDraft(newIn: projectID, statusID: defaultStatus(in: projectID)?.id ?? "", assignee: onlyMine ? user?.id : nil)
        editingDescription = false
        saveState = .idle
        screen = .editor
        titleFocusRequest += 1
    }

    /// Opens a task's page. Its title is not focused, so the page's single-key shortcuts work.
    func edit(_ task: OrbitTask?) {
        guard let task else { return }
        selectedID = task.id
        draft = TaskDraft(task: task)
        editingDescription = false
        saveState = .idle
        screen = .editor
        // AppKit would focus the title as the first key view: keep the page's shortcuts working.
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        Task { await refreshOpenTask(task.id) }
    }

    /// The list can be a little stale: the page loads the latest copy when nothing was changed yet.
    private func refreshOpenTask(_ id: String) async {
        guard let client, let workspaceID, let latest = try? await client.task(workspaceID, taskID: id) else { return }
        replace(latest)
        guard let draft, draft.taskID == id, draft.body() == nil, !editingDescription,
              latest.version > (draft.original?.version ?? 0) else { return }
        self.draft = TaskDraft(task: latest)
    }

    /// The first "to do" status of a project, or its first status.
    func defaultStatus(in projectID: String) -> TaskStatus? {
        let list = statuses(of: projectID)
        return list.first { $0.category == "unstarted" } ?? list.first
    }

    /// Changes the open draft; an existing task saves at once.
    func updateDraft(_ change: (inout TaskDraft) -> Void) {
        guard var draft else { return }
        let projectBefore = draft.projectID
        change(&draft)
        if draft.projectID != projectBefore {
            // A status of the new project in the same category.
            let category = statusByID[draft.statusID]?.category
            let list = statuses(of: draft.projectID)
            draft.statusID = (list.first { $0.category == category } ?? defaultStatus(in: draft.projectID))?.id ?? ""
        }
        self.draft = draft
        if !draft.isNew { Task { await commitDraft() } }
    }

    func cycleDraftStatus() {
        updateDraft { draft in
            let list = statuses(of: draft.projectID)
            guard !list.isEmpty else { return }
            let index = list.firstIndex { $0.id == draft.statusID } ?? -1
            draft.statusID = list[(index + 1) % list.count].id
        }
    }

    func toggleDraftAssignMe() {
        guard let me = user?.id else { return }
        updateDraft { draft in
            if draft.assigneeIDs.contains(me) { draft.assigneeIDs.remove(me) } else { draft.assigneeIDs.insert(me) }
        }
    }

    var canSave: Bool {
        guard let draft, !isBusy else { return false }
        return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.statusID.isEmpty
    }

    /// Creates the new task and goes back to the list.
    func createDraft() async {
        guard canSave, let draft, draft.isNew, let body = draft.body(), let client, let workspaceID else { return }
        isBusy = true
        defer { isBusy = false }
        await perform(showsLoading: false) {
            let task = try await client.createTask(workspaceID, body: body)
            Prefs.lastProjectForNew = draft.projectID
            self.tasks.append(task)
            self.selectedID = task.id
            self.closePage()
        }
    }

    /// Saves what changed on an existing task. Changes made while a save runs go in a second save.
    /// An empty title is not sent (the server refuses it); it is restored when the page closes.
    @discardableResult
    func commitDraft() async -> Bool {
        guard let client, let workspaceID, draft?.isNew == false else { return true }
        if isCommitting { commitQueued = true; return true }
        isCommitting = true
        defer { isCommitting = false }
        var conflicts = 0
        repeat {
            commitQueued = false
            guard let current = draft, let id = current.taskID, var body = current.body() else { break }
            if current.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["title"] = nil }
            guard body.keys.contains(where: { $0 != "expected_version" }) else { break }
            saveState = .saving
            do {
                let updated = try await client.updateTask(workspaceID, taskID: id, body: body)
                guard self.client === client else { return false }
                replace(updated)
                if draft?.taskID == id { draft?.original = updated }
                saveState = .saved
            } catch OrbitError.unauthorized {
                forgetSession()
                errorMessage = OrbitError.unauthorized.errorDescription
                return false
            } catch {
                guard self.client === client else { return false }
                saveState = .failed
                if case OrbitError.problem(409, _, _) = error, conflicts < conflictRetriesLimit,
                   let latest = try? await client.task(workspaceID, taskID: id), self.client === client {
                    // Someone else changed the task: keep these edits on top of the latest version. A conflict
                    // that keeps coming back is shown instead of retried forever.
                    conflicts += 1
                    replace(latest)
                    if draft?.taskID == id { draft?.original = latest; commitQueued = true; continue }
                }
                errorMessage = error.localizedDescription
                return false
            }
        } while commitQueued
        return true
    }

    /// Back to the list. An existing task saves first and stays open when that fails; a new one is discarded.
    func closePage() {
        if let draft, !draft.isNew {
            Task {
                guard await commitDraft() else { return }
                if self.draft?.taskID == draft.taskID { self.finishClosing() }
            }
        } else {
            finishClosing()
        }
    }

    func finishClosing() {
        editingDescription = false
        screen = .list
        draft = nil
    }

    func cancelEdit() { closePage() }

    /// Stores a copy of a task from the server. An older copy (a slow refresh that started before a
    /// write) never replaces a newer one: its version would make the next write conflict.
    /// `force` is for optimistic local changes, which keep the server's version.
    private func replace(_ task: OrbitTask, force: Bool = false) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { tasks.append(task); return }
        if force || task.version >= tasks[index].version { tasks[index] = task }
    }

    /// The writes of each task run one after the other, each with the version the previous one returned.
    private var writeChains: [String: Task<Void, Never>] = [:]

    /// An optimistic quick change from the list (status, priority, assignee): shown at once, sent in order.
    /// `local` must give the same result when applied twice. `body` builds the request from the task with
    /// `local` applied, so a retry after a conflict sends the change on top of the other person's edit.
    private func quickUpdate(_ task: OrbitTask, local: @escaping (inout OrbitTask) -> Void, body: @escaping (OrbitTask) -> JSONBody) {
        guard let client, let workspaceID else { return }
        if var current = tasks.first(where: { $0.id == task.id }) {
            local(&current)
            replace(current, force: true)
        }
        let previous = writeChains[task.id]
        let chain = Task { [weak self] in
            await previous?.value
            await self?.send(taskID: task.id, body: body, client: client, workspaceID: workspaceID, local: local)
        }
        writeChains[task.id] = chain
    }

    /// Sends one quick change with the newest known version. A conflict (someone else changed the
    /// task) loads the latest copy and sends the change once more on top of it.
    private func send(taskID: String, body: (OrbitTask) -> JSONBody, client: OrbitClient, workspaceID: String, local: (inout OrbitTask) -> Void) async {
        for attempt in 0..<2 {
            guard !Task.isCancelled, self.client === client, var current = tasks.first(where: { $0.id == taskID }) else { return }
            local(&current)
            var request = body(current)
            request["expected_version"] = current.version
            do {
                let updated = try await client.updateTask(workspaceID, taskID: taskID, body: request)
                guard self.client === client else { return }
                replace(updated)
                if draft?.taskID == taskID, draft?.body() == nil { draft = TaskDraft(task: updated) }
                return
            } catch OrbitError.problem(409, _, _) where attempt == 0 {
                guard let latest = try? await client.task(workspaceID, taskID: taskID), self.client === client else { break }
                var shown = latest
                local(&shown)
                replace(OrbitTask(copying: shown, version: latest.version), force: true)
            } catch OrbitError.unauthorized {
                forgetSession()
                errorMessage = OrbitError.unauthorized.errorDescription
                return
            } catch {
                guard self.client === client, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                break
            }
        }
        // Show what the server really has.
        guard self.client === client else { return }
        if let latest = try? await client.task(workspaceID, taskID: taskID), self.client === client { replace(latest, force: true) }
    }

    func toggleDone(_ task: OrbitTask?) {
        guard let task else { return }
        let list = statuses(of: task.projectId)
        let target = isDone(task)
            ? (list.first { $0.category == "unstarted" } ?? list.first { !$0.isDone })
            : list.first { $0.category == "completed" }
        guard let target else { return }
        setStatus(task, target)
    }

    func setStatus(_ task: OrbitTask, _ status: TaskStatus) {
        guard status.id != task.statusId else { return }
        quickUpdate(task, local: { $0.statusId = status.id }, body: { _ in ["status_id": status.id] })
    }

    func cycleStatus(_ task: OrbitTask?) {
        guard let task else { return }
        let list = statuses(of: task.projectId)
        guard let index = list.firstIndex(where: { $0.id == task.statusId }), !list.isEmpty else { return }
        setStatus(task, list[(index + 1) % list.count])
    }

    func cyclePriority(_ task: OrbitTask?) {
        guard let task else { return }
        setPriority(task, (Priority(rawValue: task.priority) ?? .none).next)
    }

    func setPriority(_ task: OrbitTask, _ priority: Priority) {
        quickUpdate(task, local: { $0.priority = priority.rawValue }, body: { _ in ["priority": priority.rawValue] })
    }

    func toggleAssignMe(_ task: OrbitTask?) {
        guard let task, let me = user?.id else { return }
        // The intent (add or remove me) is fixed now; the list it applies to is the newest one at send time,
        // so someone else's assignee change made meanwhile is kept.
        let adding = !task.assigneeIds.contains(me)
        quickUpdate(task, local: { task in
            task.assigneeIds.removeAll { $0 == me }
            if adding { task.assigneeIds.append(me) }
        }, body: { ["assignee_ids": $0.assigneeIds] })
    }

    func requestTrash(_ task: OrbitTask?) {
        confirmTrash = task
    }

    func trashConfirmed() async {
        guard let requested = confirmTrash, let client, let workspaceID else { return }
        confirmTrash = nil
        // Quick changes still being sent would change the version: let them finish, then use the newest copy.
        await writeChains[requested.id]?.value
        guard self.client === client, let task = tasks.first(where: { $0.id == requested.id }) else { return }
        let visible = visibleTasks
        let next = visible.firstIndex(of: task).map { index in
            visible.indices.contains(index + 1) ? visible[index + 1].id : (index > 0 ? visible[index - 1].id : nil)
        } ?? nil
        await perform(showsLoading: false) {
            do {
                try await client.trashTask(workspaceID, taskID: task.id, version: task.version)
            } catch OrbitError.problem(409, _, _) {
                // Changed meanwhile (an editor save, someone else): trash the latest version.
                let latest = try await client.task(workspaceID, taskID: task.id)
                try await client.trashTask(workspaceID, taskID: task.id, version: latest.version)
            }
            guard self.client === client else { return }
            self.tasks.removeAll { $0.id == task.id }
            self.selectedID = next
            if self.draft?.taskID == task.id { self.finishClosing() }
        }
    }

    // MARK: - Status picker

    struct StatusPicker: Equatable {
        enum Target: Equatable { case task(String), draft }
        var target: Target
        var query = ""
        var highlighted = 0
    }

    func openStatusPicker(for target: StatusPicker.Target) {
        let current: String?
        switch target {
        case .task(let id): current = tasks.first { $0.id == id }?.statusId
        case .draft: current = draft?.statusID
        }
        var picker = StatusPicker(target: target)
        picker.highlighted = statusOptions(for: picker).firstIndex { $0.id == current } ?? 0
        statusPicker = picker
    }

    /// The statuses of the target's project that match the typed query, in board order.
    func statusOptions(for picker: StatusPicker) -> [TaskStatus] {
        let projectID: String?
        switch picker.target {
        case .task(let id): projectID = tasks.first { $0.id == id }?.projectId
        case .draft: projectID = draft?.projectID
        }
        let all = projectID.map(statuses(of:)) ?? []
        let query = picker.query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? all : all.filter { $0.name.lowercased().contains(query) }
    }

    func pickerCurrentStatus(_ picker: StatusPicker) -> String? {
        switch picker.target {
        case .task(let id): return tasks.first { $0.id == id }?.statusId
        case .draft: return draft?.statusID
        }
    }

    func chooseStatus(_ status: TaskStatus) {
        guard let picker = statusPicker else { return }
        switch picker.target {
        case .task(let id):
            if let task = tasks.first(where: { $0.id == id }) { setStatus(task, status) }
        case .draft:
            updateDraft { $0.statusID = status.id }
        }
        closeStatusPicker()
    }

    func closeStatusPicker() {
        statusPicker = nil
        DispatchQueue.main.async { self.refocusPanel() }
    }

    func moveStatusHighlight(_ step: Int) {
        guard var picker = statusPicker else { return }
        let count = statusOptions(for: picker).count
        guard count > 0 else { return }
        picker.highlighted = (picker.highlighted + step + count) % count
        statusPicker = picker
    }

    // MARK: - Links

    func taskURL(_ task: OrbitTask) -> URL? {
        client?.server.appendingPathComponent("tasks").appendingPathComponent(task.id)
    }

    func openInBrowser(_ task: OrbitTask?) {
        guard let task, let url = taskURL(task) else { return }
        NSWorkspace.shared.open(url)
        closePanel()
    }

    func openOrbit() {
        guard let server = client?.server else { return }
        NSWorkspace.shared.open(server)
        closePanel()
    }

    func copyLink(_ task: OrbitTask?) {
        guard let task, let url = taskURL(task) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        flash("Copied link to \(identifier(task))")
    }

    var toast: String?
    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toast == message { toast = nil }
        }
    }
}
