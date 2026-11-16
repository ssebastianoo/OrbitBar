import SwiftUI

struct RootView: View {
    static let width: CGFloat = 440
    static let height: CGFloat = 580

    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignInView()
            case .signedIn:
                switch model.screen {
                case .list: TaskListView()
                case .editor: TaskDetailView()
                case .account: AccountView()
                case .help: HelpView()
                }
            }

            if let task = model.confirmTrash {
                TrashConfirmation(task: task)
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(.bottom, 40)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }
}

private struct TrashConfirmation: View {
    @Environment(AppModel.self) private var model
    var task: OrbitTask

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.confirmTrash = nil }
            VStack(alignment: .leading, spacing: 10) {
                Text("Move \(model.identifier(task)) to the trash?").font(.headline)
                Text(task.title).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Spacer()
                    Button("Cancel") { model.confirmTrash = nil }
                    Button("Move to Trash", role: .destructive) { Task { await model.trashConfirmed() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                HStack(spacing: 10) {
                    Hint(keys: "⏎", title: "confirm")
                    Hint(keys: "esc", title: "cancel")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 320)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .shadow(radius: 12)
        }
    }
}
