import AppKit

/// Every keyboard shortcut of the panel, in one place. The panel controller feeds it the key-down
/// events of its window; a `true` answer consumes the event.
enum Key {
    static let returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53, delete: UInt16 = 51, forwardDelete: UInt16 = 117
    static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124, space: UInt16 = 49
}

struct Shortcut: Identifiable {
    var id: String { keys + title }
    var keys: String
    var title: String
}

enum Shortcuts {
    static let global: [Shortcut] = [
        .init(keys: "⌥⌘O", title: "Show or hide Orbit (anywhere)"),
        .init(keys: "⌥⌘N", title: "New task (anywhere)"),
    ]
    static let list: [Shortcut] = [
        .init(keys: "↑ ↓  or  k j", title: "Move selection"),
        .init(keys: "⏎  or  e", title: "Edit task"),
        .init(keys: "n  ⌘N", title: "New task"),
        .init(keys: "x  or  space", title: "Mark done / not done"),
        .init(keys: "s", title: "Change status (then 1…9 or ↑↓ ⏎)"),
        .init(keys: "p", title: "Next priority"),
        .init(keys: "a", title: "Assign / unassign me"),
        .init(keys: "o  ⌘O", title: "Open in browser"),
        .init(keys: "c", title: "Copy link"),
        .init(keys: "⌫", title: "Move to trash"),
        .init(keys: "/  ⌘F", title: "Search"),
        .init(keys: "m", title: "My tasks / all tasks"),
        .init(keys: "h", title: "Show / hide done"),
        .init(keys: "[  ]", title: "Previous / next project"),
        .init(keys: "⌘[  ⌘]  ⌘1…9", title: "Switch workspace"),
        .init(keys: "r  ⌘R", title: "Refresh"),
        .init(keys: "⌘,", title: "Account"),
        .init(keys: "?", title: "This help"),
        .init(keys: "esc", title: "Clear search / close"),
    ]
    static let editor: [Shortcut] = [
        .init(keys: "e", title: "Edit description"),
        .init(keys: "t", title: "Edit title"),
        .init(keys: "s", title: "Change status"),
        .init(keys: "p  a", title: "Next priority / assign me"),
        .init(keys: "d", title: "Due date"),
        .init(keys: "o  c", title: "Open in browser / copy link"),
        .init(keys: "esc", title: "End editing, then back (saves)"),
        .init(keys: "⌘⏎", title: "Create task / done"),
        .init(keys: "⌘⌫", title: "Move to trash"),
    ]
}

extension AppModel {
    /// `editingText`: a text field or text view has the focus.
    func handleKey(_ event: NSEvent, editingText: Bool, inSearchField: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode

        if command && key == "q" { NSApp.terminate(nil); return true }

        if statusPicker != nil { return handleStatusPickerKey(code: code, key: key, command: command) }

        if confirmTrash != nil {
            switch code {
            case Key.returnKey, Key.enter: Task { await trashConfirmed() }; return true
            case Key.escape: confirmTrash = nil; return true
            default: return true
            }
        }

        guard phase == .signedIn else {
            if code == Key.escape {
                if signInStep != .credentials { cancelSignInStep() } else { closePanel() }
                return true
            }
            return false
        }

        switch screen {
        case .editor: return handleEditorKey(code: code, key: key, command: command, editingText: editingText)
        case .help, .account:
            if code == Key.escape || key == "?" && !editingText || command && key == "," {
                screen = draft != nil ? .editor : .list
                return true
            }
            return false
        case .list:
            return handleListKey(code: code, key: key, command: command, flags: flags, editingText: editingText, inSearchField: inSearchField)
        }
    }

    /// The picker's search field keeps every other key.
    private func handleStatusPickerKey(code: UInt16, key: String, command: Bool) -> Bool {
        guard let picker = statusPicker else { return false }
        switch code {
        case Key.escape: closeStatusPicker(); return true
        case Key.up: moveStatusHighlight(-1); return true
        case Key.down: moveStatusHighlight(1); return true
        case Key.returnKey, Key.enter:
            let options = statusOptions(for: picker)
            if options.indices.contains(picker.highlighted) { chooseStatus(options[picker.highlighted]) }
            return true
        default: break
        }
        if !command, picker.query.isEmpty, let number = Int(key), (1...9).contains(number) {
            let options = statusOptions(for: picker)
            if options.indices.contains(number - 1) { chooseStatus(options[number - 1]) }
            return true
        }
        return false
    }

    private func handleEditorKey(code: UInt16, key: String, command: Bool, editingText: Bool) -> Bool {
        let isNew = draft?.isNew ?? true
        if command && (code == Key.returnKey || code == Key.enter) {
            if isNew { Task { await createDraft() } } else { closePage() }
            return true
        }
        if command && key == "s" {
            if isNew { Task { await createDraft() } } else { Task { await commitDraft() } }
            return true
        }
        if command && code == Key.delete && !editingText, let id = draft?.taskID {
            requestTrash(tasks.first { $0.id == id })
            return true
        }
        if code == Key.escape {
            if editingText || editingDescription {
                // First esc ends the edit (and saves); the next one leaves the page.
                editingDescription = false
                NSApp.keyWindow?.makeFirstResponder(nil)
                if !isNew { Task { await commitDraft() } }
            } else {
                closePage()
            }
            return true
        }
        guard !editingText, !command else { return false }
        switch key {
        case "e": editingDescription = true
        case "t": titleFocusRequest += 1
        case "s": openStatusPicker(for: .draft)
        case "p": updateDraft { $0.priority = $0.priority.next }
        case "a": toggleDraftAssignMe()
        case "d": showDuePicker = true
        case "o": openInBrowser(draft?.original)
        case "c": copyLink(draft?.original)
        case "?": screen = .help
        default: return false
        }
        return true
    }

    private func handleListKey(code: UInt16, key: String, command: Bool, flags: NSEvent.ModifierFlags, editingText: Bool, inSearchField: Bool) -> Bool {
        // Command shortcuts work everywhere in the list, also while typing a search.
        if command {
            switch key {
            case "n": newTask(); return true
            case "f": searchFocusRequest += 1; return true
            case "r": Task { await refresh() }; return true
            case "o": openInBrowser(selectedTask); return true
            case ",": screen = .account; return true
            case "[": cycleWorkspace(-1); return true
            case "]": cycleWorkspace(1); return true
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                let index = Int(key)! - 1
                if workspaces.indices.contains(index) { Task { await selectWorkspace(workspaces[index].id) } }
                return true
            default: break
            }
            if code == Key.delete && !editingText { requestTrash(selectedTask); return true }
            return false
        }

        if editingText {
            guard inSearchField else { return false }
            switch code {
            case Key.up: moveSelection(-1); return true
            case Key.down: moveSelection(1); return true
            case Key.returnKey, Key.enter: edit(selectedTask); return true
            case Key.escape:
                if search.isEmpty { NSApp.keyWindow?.makeFirstResponder(nil) } else { search = "" }
                return true
            default: return false
            }
        }

        switch code {
        case Key.up: moveSelection(-1); return true
        case Key.down: moveSelection(1); return true
        case Key.returnKey, Key.enter: edit(selectedTask); return true
        case Key.space: toggleDone(selectedTask); return true
        case Key.delete, Key.forwardDelete: requestTrash(selectedTask); return true
        case Key.escape:
            if !search.isEmpty { search = "" } else { closePanel() }
            return true
        default: break
        }

        guard flags.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty else { return false }
        switch key {
        case "j": moveSelection(1)
        case "k": moveSelection(-1)
        case "g": selectedID = visibleTasks.first?.id
        case "e": edit(selectedTask)
        case "n": newTask()
        case "x": toggleDone(selectedTask)
        case "s": if let id = selectedID { openStatusPicker(for: .task(id)) }
        case "p": cyclePriority(selectedTask)
        case "a": toggleAssignMe(selectedTask)
        case "o": openInBrowser(selectedTask)
        case "c": copyLink(selectedTask)
        case "/": searchFocusRequest += 1
        case "m": setOnlyMine(!onlyMine)
        case "h": setShowDone(!showDone)
        case "[": cycleProjectFilter(-1)
        case "]": cycleProjectFilter(1)
        case "r": Task { await refresh() }
        case "?": screen = .help
        default: return false
        }
        return true
    }
}
