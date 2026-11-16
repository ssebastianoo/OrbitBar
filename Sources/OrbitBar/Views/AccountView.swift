import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            BackHeader(title: "Account")
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if let user = model.user {
                    HStack(spacing: 10) {
                        Avatar(member: Member(id: user.id, userId: user.id, email: user.email, displayName: user.displayName, avatarUrl: user.avatarUrl), size: 36)
                        VStack(alignment: .leading) {
                            Text(user.displayName).font(.headline)
                            Text(user.email).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Server", value: model.client?.server.absoluteString ?? "—")
                LabeledContent("Workspaces", value: "\(model.workspaces.count)")

                HStack {
                    Button("Open Orbit in Browser") { model.openOrbit() }
                    Spacer()
                    Button("Sign Out") { Task { await model.signOut() } }
                }

                Divider()
                Text("Global shortcuts").font(.headline)
                ForEach(Shortcuts.global) { ShortcutRow(shortcut: $0) }

                Spacer()
                HStack {
                    Spacer()
                    Button("Quit OrbitBar") { NSApp.terminate(nil) }
                }
            }
            .padding(16)
        }
    }
}

struct HelpView: View {
    var body: some View {
        VStack(spacing: 0) {
            BackHeader(title: "Keyboard Shortcuts")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    section("Anywhere", Shortcuts.global)
                    section("Task list", Shortcuts.list)
                    section("Task page", Shortcuts.editor)
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ shortcuts: [Shortcut]) -> some View {
        Text(title).font(.headline).padding(.top, 6)
        ForEach(shortcuts) { ShortcutRow(shortcut: $0) }
    }
}

private struct ShortcutRow: View {
    var shortcut: Shortcut
    var body: some View {
        HStack {
            Text(shortcut.title)
            Spacer()
            KeyCap(text: shortcut.keys)
        }
        .font(.callout)
    }
}

private struct BackHeader: View {
    @Environment(AppModel.self) private var model
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            Button { model.screen = model.draft != nil ? .editor : .list } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back (esc)")
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
