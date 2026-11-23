import Foundation

#if DEBUG
private let demoDescription = """
The pricing page should match the new **brand guidelines** and make the *Team* plan the default choice.

## Scope
- New hero with a plan toggle (monthly / yearly)
- Comparison table, see `PricingTable.tsx`
- [x] Copy reviewed by marketing
- [ ] Final screenshots

> Keep the FAQ section, it converts well.

![Mockup](https://picsum.photos/seed/orbit/640/320)

Details in the [design doc](https://example.com/design).
"""

/// `ORBITBAR_DEMO=1`: sample data without a server, for checking the UI.
extension AppModel {
    func loadDemo() {
        let me = User(id: "u1", email: "you@example.com", displayName: "You Example")
        user = me
        workspaces = [Workspace(id: "w1", name: "Acme", role: "owner"), Workspace(id: "w2", name: "Side Project", role: "member")]
        workspaceID = "w1"
        projects = [Project(id: "p1", name: "Website", key: "WEB", color: "#8b5cf6"), Project(id: "p2", name: "Mobile", key: "MOB", color: "#10b981")]
        let statuses = ["p1", "p2"].flatMap { p in [
            TaskStatus(id: "\(p)-backlog", projectId: p, name: "Backlog", color: "#9ca3af", category: "unstarted", position: 0),
            TaskStatus(id: "\(p)-todo", projectId: p, name: "Todo", color: "#9ca3af", category: "unstarted", position: 1),
            TaskStatus(id: "\(p)-doing", projectId: p, name: "In Progress", color: "#f59e0b", category: "started", position: 2),
            TaskStatus(id: "\(p)-done", projectId: p, name: "Done", color: "#8b5cf6", category: "completed", position: 3),
        ] }
        statusesByProject = Dictionary(grouping: statuses, by: \.projectId)
        statusByID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        members = [Member(id: "m1", userId: "u1", email: me.email, displayName: me.displayName), Member(id: "m2", userId: "u2", email: "sam@example.com", displayName: "Sam Rivera")]
        let now = Date()
        func task(_ n: Int, _ p: String, _ s: String, _ title: String, _ priority: String, due: Int? = nil, assignees: [String] = ["u1"]) -> OrbitTask {
            OrbitTask(id: "t\(n)", workspaceId: "w1", projectId: p, statusId: "\(p)-\(s)", number: n, title: title, description: n == 12 ? demoDescription : "", priority: priority, position: n, assigneeIds: assignees, labelIds: [], dueAt: due.map { OrbitDate.format(now.addingTimeInterval(Double($0) * 86400)) }, version: 1, createdAt: OrbitDate.format(now), updatedAt: OrbitDate.format(now))
        }
        tasks = [
            task(12, "p1", "doing", "Redesign pricing page", "high", due: 1, assignees: ["u1", "u2"]),
            task(14, "p2", "doing", "Fix push notification crash on iOS 27", "urgent", due: -1),
            task(9, "p1", "todo", "Write launch blog post", "medium", due: 4),
            task(21, "p2", "todo", "Offline mode for task list", "low"),
            task(3, "p1", "todo", "Audit accessibility of sign-in", "none", due: 9),
            task(7, "p1", "done", "Set up preview deployments", "medium"),
            task(25, "p2", "backlog", "Widgets for the home screen", "low"),
        ]
        selectedID = "t14"
        phase = .signedIn
        switch ProcessInfo.processInfo.environment["ORBITBAR_SCREEN"] {
        case "editor": edit(tasks.first)
        case "new": newTask()
        case "help": screen = .help
        case "account": screen = .account
        case "picker":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.openStatusPicker(for: .task("t14")) }
        default: break
        }
    }
}
#endif

#if DEBUG
import AppKit
import SwiftUI

/// `ORBITBAR_SNAPSHOT=<dir>`: renders each screen with demo data to PNGs offscreen, then quits.
@MainActor
enum Snapshots {
    static func run(to directory: String) {
        let model = AppModel()
        model.loadDemo()
        let screens: [(String, () -> Void)] = [
            ("list", { model.screen = .list }),
            ("editor", { model.edit(model.tasks.first) }),
            ("new", { model.newTask() }),
            ("help", { model.screen = .help }),
            ("account", { model.screen = .account }),
            ("trash", { model.screen = .list; model.confirmTrash = model.tasks.first }),
            ("signin", { model.confirmTrash = nil; model.phase = .signedOut }),
        ]
        for (name, setUp) in screens {
            setUp()
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: RootView.width, height: RootView.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .windowBackgroundColor
            let view = NSHostingView(rootView: RootView().environment(model))
            view.frame = NSRect(x: 0, y: 0, width: RootView.width, height: RootView.height)
            window.contentView = view
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }
        exit(0)
    }
}
#endif
