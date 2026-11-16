import MarkdownUI
import SwiftUI

/// A task's page, after Orbit's own: breadcrumb, large title, properties as compact chips, then the
/// description rendered as Markdown. Existing tasks save each change on their own; a new task is
/// created with ⌘⏎.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let draft = model.draft {
            TaskPage(current: draft)
        } else {
            Color.clear.onAppear { model.screen = .list }
        }
    }
}

private struct TaskPage: View {
    @Environment(AppModel.self) private var model
    var current: TaskDraft
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool

    /// Falls back to the last rendered draft: after the page closes, SwiftUI can still read these
    /// bindings once while it is torn down. Writes after that are dropped.
    private var draft: Binding<TaskDraft> {
        Binding(get: { model.draft ?? current }, set: { if model.draft != nil { model.draft = $0 } })
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(current: current)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { model.errorMessage = nil }
                    }

                    TextField("Untitled task", text: draft.title, axis: .vertical)
                        .font(.system(size: 19, weight: .semibold))
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($titleFocused)
                        .onSubmit {
                            if current.isNew { Task { await model.createDraft() } } else { titleFocused = false }
                        }

                    PropertyChips(current: current)

                    Divider()

                    DescriptionSection(current: current, draft: draft, focused: $descriptionFocused)

                    if let task = current.original {
                        MetaLine(task: task)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if current.isNew {
                Divider()
                NewTaskBar()
            }
        }
        .onAppear { if current.isNew { titleFocused = true } }
        .onChange(of: model.titleFocusRequest) { titleFocused = true }
        .onChange(of: titleFocused) { _, focused in
            if !focused && !current.isNew { Task { await model.commitDraft() } }
        }
        .onChange(of: model.editingDescription) { _, editing in
            descriptionFocused = editing
            if !editing && !current.isNew { Task { await model.commitDraft() } }
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model
    var current: TaskDraft

    var body: some View {
        HStack(spacing: 6) {
            Button { model.closePage() } label: { Image(systemName: "chevron.left") }
                .help("Back (esc)")

            if let project = model.project(current.projectID) {
                Circle().fill(Color(hex: project.color)).frame(width: 7, height: 7)
                Text(project.name).lineLimit(1).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            Text(current.original.map(model.identifier) ?? "New task")
                .font(.system(size: 12, weight: .medium, design: current.isNew ? .default : .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            SaveIndicator()

            if let task = current.original {
                Button { model.openInBrowser(task) } label: { Image(systemName: "safari") }
                    .help("Open in browser (o)")
                Menu {
                    Button("Open in Browser") { model.openInBrowser(task) }
                    Button("Copy Link") { model.copyLink(task) }
                    Divider()
                    Button("Move to Trash…", role: .destructive) { model.requestTrash(task) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct SaveIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.saveState {
            case .saving:
                ProgressView().controlSize(.mini)
            case .saved:
                Label("Saved", systemImage: "checkmark").foregroundStyle(.tertiary)
            case .failed:
                Label("Not saved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11))
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: model.saveState)
    }
}

// MARK: - Properties

private struct PropertyChips: View {
    @Environment(AppModel.self) private var model
    var current: TaskDraft

    var body: some View {
        @Bindable var model = model
        let status = model.statusByID[current.statusID]
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Button { model.openStatusPicker(for: .draft) } label: {
                Chip {
                    StatusIcon(status: status, size: 12)
                    Text(status?.name ?? "Status")
                }
            }
            .buttonStyle(.plain)
            .help("Status (s)")
            .statusPicker(model, for: .draft)

            Menu {
                ForEach(Priority.allCases.reversed()) { option in
                    Button {
                        model.updateDraft { $0.priority = option }
                    } label: {
                        Label(option.title, systemImage: option == current.priority ? "checkmark" : option.symbol)
                    }
                }
            } label: {
                Chip(muted: current.priority == .none) {
                    if current.priority == .none {
                        Image(systemName: "ellipsis")
                    } else {
                        PriorityIcon(priority: current.priority)
                    }
                    Text(current.priority == .none ? "Priority" : current.priority.title)
                }
            }
            .chipMenu()
            .help("Priority (p)")

            Menu {
                if let me = model.user?.id {
                    Button(current.assigneeIDs.contains(me) ? "Unassign Me" : "Assign to Me") { model.toggleDraftAssignMe() }
                    Divider()
                }
                ForEach(model.members) { member in
                    Button {
                        model.updateDraft { draft in
                            if draft.assigneeIDs.contains(member.userId) { draft.assigneeIDs.remove(member.userId) } else { draft.assigneeIDs.insert(member.userId) }
                        }
                    } label: {
                        Label(member.displayName, systemImage: current.assigneeIDs.contains(member.userId) ? "checkmark" : "person")
                    }
                }
                if !current.assigneeIDs.isEmpty {
                    Divider()
                    Button("Clear Assignees") { model.updateDraft { $0.assigneeIDs = [] } }
                }
            } label: {
                Chip(muted: current.assigneeIDs.isEmpty) {
                    if current.assigneeIDs.isEmpty {
                        Image(systemName: "person")
                        Text("Assign")
                    } else {
                        let ids = current.assigneeIDs.sorted()
                        HStack(spacing: -4) {
                            ForEach(ids.prefix(3), id: \.self) { Avatar(member: model.member($0), size: 15) }
                        }
                        Text(ids.count == 1 ? (model.member(ids[0])?.displayName ?? "1 person") : "\(ids.count) people")
                    }
                }
            }
            .chipMenu()
            .help("Assignees (a assigns you)")

            Button { model.showDuePicker.toggle() } label: {
                Chip(muted: !current.hasDue) {
                    Image(systemName: "calendar")
                    if current.hasDue {
                        Text(DueFormat.label(current.due))
                            .foregroundStyle(DueFormat.isOverdue(OrbitDate.endOfDay(current.due)) ? Color.red : Color.primary)
                    } else {
                        Text("Due date")
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Due date (d)")
            .popover(isPresented: $model.showDuePicker, arrowEdge: .bottom) { DuePicker(current: current) }

            Menu {
                ForEach(model.projects) { project in
                    Button {
                        model.updateDraft { $0.projectID = project.id }
                    } label: {
                        Label(project.name, systemImage: project.id == current.projectID ? "checkmark" : "folder")
                    }
                }
            } label: {
                Chip {
                    Circle().fill(Color(hex: model.project(current.projectID)?.color ?? "#9ca3af")).frame(width: 7, height: 7)
                    Text(model.project(current.projectID)?.name ?? "Project")
                }
            }
            .chipMenu()
            .help("Project")
        }
    }
}

/// A rounded, lightly filled property pill.
private struct Chip<Content: View>: View {
    var muted = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.system(size: 12))
            .foregroundStyle(muted ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.1 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private extension View {
    func chipMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

private struct DuePicker: View {
    @Environment(AppModel.self) private var model
    var current: TaskDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                quick("Today", days: 0)
                quick("Tomorrow", days: 1)
                quick("Next week", days: 7)
            }
            DatePicker("", selection: Binding(
                get: { current.due },
                set: { date in model.updateDraft { $0.hasDue = true; $0.due = date } }
            ), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            if current.hasDue {
                Button("Remove Due Date", role: .destructive) {
                    model.updateDraft { $0.hasDue = false }
                    model.showDuePicker = false
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
    }

    private func quick(_ title: String, days: Int) -> some View {
        Button(title) {
            let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
            model.updateDraft { $0.hasDue = true; $0.due = date }
            model.showDuePicker = false
        }
        .controlSize(.small)
    }
}

// MARK: - Description

private struct DescriptionSection: View {
    @Environment(AppModel.self) private var model
    var current: TaskDraft
    var draft: Binding<TaskDraft>
    var focused: FocusState<Bool>.Binding
    @State private var hovering = false

    var body: some View {
        if model.editingDescription || (current.isNew && !current.description.isEmpty) {
            editor
        } else if current.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button { model.editingDescription = true } label: {
                Text("Add a description…")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit description (e)")
        } else {
            rendered
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: draft.description)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused(focused)
                .frame(minHeight: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.5)))
            HStack(spacing: 8) {
                Text("Markdown").foregroundStyle(.tertiary)
                Spacer()
                if !current.isNew {
                    Hint(keys: "esc", title: "done").foregroundStyle(.secondary)
                    Button("Done") { model.editingDescription = false }.controlSize(.small)
                }
            }
            .font(.caption)
        }
        .onAppear { focused.wrappedValue = true }
    }

    private var rendered: some View {
        Markdown(current.description, baseURL: model.client?.server, imageBaseURL: model.client?.server)
            .markdownTheme(.orbit)
            .markdownImageProvider(AuthorizedImageProvider(client: model.client))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { model.editingDescription = true } label: {
                        Label("Edit", systemImage: "pencil").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Edit description (e)")
                    .offset(y: -4)
                }
            }
            .onHover { hovering = $0 }
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                model.closePanel()
                return .handled
            })
    }
}

// MARK: - Footer

private struct MetaLine: View {
    @Environment(AppModel.self) private var model
    var task: OrbitTask

    var body: some View {
        let formatter = RelativeDateTimeFormatter()
        let created = OrbitDate.parse(task.createdAt).map { formatter.localizedString(for: $0, relativeTo: Date()) }
        let updated = OrbitDate.parse(task.updatedAt).map { formatter.localizedString(for: $0, relativeTo: Date()) }
        let creator = task.creatorId.flatMap { model.member($0)?.displayName }
        HStack(spacing: 4) {
            if let creator { Text("Created by \(creator)") } else { Text("Created") }
            if let created { Text(created) }
            if let updated, task.updatedAt != task.createdAt {
                Text("·")
                Text("Updated \(updated)")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
    }
}

private struct NewTaskBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Hint(keys: "⌘⏎", title: "create").font(.caption).foregroundStyle(.secondary)
            Hint(keys: "esc", title: "discard").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
            Button("Cancel") { model.closePage() }
            Button("Create Task") { Task { await model.createDraft() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
