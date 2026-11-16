import SwiftUI

struct TaskListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ListHeader()
            Divider()
            FilterBar()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            Divider()
            TaskList()
            Divider()
            ListFooter()
        }
    }
}

// MARK: - Header

private struct ListHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(model.workspaces) { workspace in
                    Button {
                        Task { await model.selectWorkspace(workspace.id) }
                    } label: {
                        if workspace.id == model.workspaceID {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }
            } label: {
                Text(model.workspace?.name ?? "No workspace").font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Workspace (⌘[ ⌘] ⌘1…9)")

            Spacer()

            if model.isLoading { ProgressView().controlSize(.small) }

            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh (r)")
            Button { model.screen = .help } label: { Image(systemName: "keyboard") }
                .help("Keyboard shortcuts (?)")
            Button { model.screen = .account } label: { Image(systemName: "person.crop.circle") }
                .help("Account (⌘,)")
            Button { model.newTask() } label: { Image(systemName: "plus") }
                .help("New task (n)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Filters

enum SearchField {
    static let placeholder = "Search tasks"
}

private struct FilterBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { model.onlyMine }, set: { model.setOnlyMine($0) })) {
                    Text("My Tasks").tag(true)
                    Text("All Tasks").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("m")

                Menu {
                    Button("All Projects") { model.setProjectFilter(nil) }
                    Divider()
                    ForEach(model.projects) { project in
                        Button { model.setProjectFilter(project.id) } label: {
                            Text("\(project.name)  ·  \(project.key)")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(model.filterProject.map { Color(hex: $0.color) } ?? .secondary).frame(width: 7, height: 7)
                        Text(model.filterProject?.name ?? "All Projects").lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Project ([ and ])")

                Spacer()

                Toggle("Done", isOn: Binding(get: { model.showDone }, set: { model.setShowDone($0) }))
                    .toggleStyle(.checkbox)
                    .help("Show done tasks (h)")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(SearchField.placeholder, text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    KeyCap(text: "/").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: searchFocused) { model.searchFocused = searchFocused }
        .onChange(of: model.search) { model.keepSelectionValid() }
    }
}

// MARK: - List

private struct TaskList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sections = model.sections
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.tasks) { task in
                                TaskRow(task: task, selected: task.id == model.selectedID)
                                    .id(task.id)
                            }
                        } header: {
                            HStack {
                                Text(StatusCategory.title(section.category))
                                Text("\(section.tasks.count)").foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.bar)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .overlay {
                if sections.isEmpty && !model.isLoading { EmptyState() }
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .onAppear { model.keepSelectionValid() }
        .onChange(of: model.tasks) { model.keepSelectionValid() }
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: model.search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(model.search.isEmpty ? (model.onlyMine ? "Nothing assigned to you" : "No tasks") : "No matching tasks")
                .foregroundStyle(.secondary)
            if model.search.isEmpty {
                Button("New Task") { model.newTask() }
            }
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    var task: OrbitTask
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        let status = model.statusByID[task.statusId]
        let done = status?.isDone ?? false
        let due = OrbitDate.parse(task.dueAt)
        HStack(spacing: 8) {
            Button {
                model.selectedID = task.id
                model.openStatusPicker(for: .task(task.id))
            } label: {
                StatusIcon(status: status)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-3)
            .help("\(status?.name ?? "Status") — change status (s)")

            Text(model.identifier(task))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)

            Text(task.title)
                .lineLimit(1)
                .strikethrough(done, color: .secondary)
                .foregroundStyle(done ? .secondary : .primary)

            Spacer(minLength: 4)

            if let due {
                Text(DueFormat.label(due))
                    .font(.caption)
                    .foregroundStyle(!done && DueFormat.isOverdue(due) ? .red : .secondary)
            }

            PriorityIcon(priority: Priority(rawValue: task.priority) ?? .none)

            HStack(spacing: -5) {
                ForEach(task.assigneeIds.prefix(3), id: \.self) { id in
                    Avatar(member: model.member(id), size: 18)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.07) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Anchored on the row so the picker opens left-aligned under the status icon, as in Linear.
        .statusPicker(model, for: .task(task.id), anchor: .point(UnitPoint(x: 0.3, y: 0.85)))
        .animation(.easeOut(duration: 0.08), value: hovering)
        .onTapGesture(count: 2) { model.edit(task) }
        .simultaneousGesture(TapGesture().onEnded { model.selectedID = task.id })
        .contextMenu { TaskContextMenu(task: task) }
    }
}

private struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    var task: OrbitTask

    var body: some View {
        let done = model.isDone(task)
        let assigned = task.assigneeIds.contains(model.user?.id ?? "")

        Button { model.edit(task) } label: { Label("Edit…", systemImage: "square.and.pencil") }
            .keyboardShortcut("e", modifiers: [])
        Button { model.toggleDone(task) } label: {
            Label(done ? "Mark Not Done" : "Mark Done", systemImage: done ? "circle" : "checkmark.circle")
        }
        .keyboardShortcut("x", modifiers: [])

        Menu {
            Picker("Status", selection: Binding(
                get: { task.statusId },
                set: { id in if let status = model.statusByID[id] { model.setStatus(task, status) } }
            )) {
                ForEach(model.statuses(of: task.projectId)) { status in
                    Label(status.name, systemImage: StatusCategory.symbol(status.category)).tag(status.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Status", systemImage: StatusCategory.symbol(model.statusByID[task.statusId]?.category ?? "unstarted"))
        }

        Menu {
            Picker("Priority", selection: Binding(
                get: { Priority(rawValue: task.priority) ?? .none },
                set: { model.setPriority(task, $0) }
            )) {
                ForEach(Priority.allCases.reversed()) { priority in
                    Label {
                        Text(priority.title)
                    } icon: {
                        Image(systemName: priority.menuSymbol.name, variableValue: priority.menuSymbol.fill)
                    }
                    .tag(priority)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Priority", systemImage: "chart.bar")
        }

        Button { model.toggleAssignMe(task) } label: {
            Label(assigned ? "Unassign Me" : "Assign to Me", systemImage: assigned ? "person.badge.minus" : "person.badge.plus")
        }
        .keyboardShortcut("a", modifiers: [])

        Divider()
        Button { model.openInBrowser(task) } label: { Label("Open in Browser", systemImage: "safari") }
            .keyboardShortcut("o", modifiers: [])
        Button { model.copyLink(task) } label: { Label("Copy Link", systemImage: "link") }
            .keyboardShortcut("c", modifiers: [])
        Divider()
        Button(role: .destructive) { model.requestTrash(task) } label: { Label("Move to Trash…", systemImage: "trash") }
            .keyboardShortcut(.delete, modifiers: [])
    }
}

// MARK: - Footer

private struct ListFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Hint(keys: "n", title: "new")
            Hint(keys: "⏎", title: "edit")
            Hint(keys: "x", title: "done")
            Hint(keys: "/", title: "search")
            Hint(keys: "?", title: "all keys")
            Spacer()
            Text("\(model.visibleTasks.count) tasks").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
