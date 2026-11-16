import SwiftUI

/// The status selector, after Linear's: a search field, the project's statuses with their number
/// keys, a check on the current one. ↑ ↓ ⏎, 1…9 and esc come through `AppModel.handleKey`.
struct StatusPickerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        if let picker = model.statusPicker {
            let options = model.statusOptions(for: picker)
            let current = model.pickerCurrentStatus(picker)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    TextField("Change status…", text: Binding(
                        get: { model.statusPicker?.query ?? "" },
                        set: { query in
                            model.statusPicker?.query = query
                            model.statusPicker?.highlighted = 0
                        }
                    ))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    KeyCap(text: "S").foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()

                VStack(spacing: 1) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, status in
                        StatusOptionRow(
                            status: status,
                            number: picker.query.isEmpty && index < 9 ? index + 1 : nil,
                            isCurrent: status.id == current,
                            isHighlighted: index == picker.highlighted
                        )
                        .onHover { if $0 { model.statusPicker?.highlighted = index } }
                        .onTapGesture { model.chooseStatus(status) }
                    }
                    if options.isEmpty {
                        Text("No matching status")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(5)
            }
            .frame(width: 230)
            .onAppear { searchFocused = true }
        }
    }
}

private struct StatusOptionRow: View {
    var status: TaskStatus
    var number: Int?
    var isCurrent: Bool
    var isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: status, size: 13)
            Text(status.name).lineLimit(1)
            Spacer(minLength: 6)
            if isCurrent {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            if let number {
                Text("\(number)").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 12, alignment: .trailing)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? Color.primary.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

extension View {
    /// Shows the status picker under this view while it targets `target`.
    func statusPicker(_ model: AppModel, for target: AppModel.StatusPicker.Target, anchor: PopoverAttachmentAnchor = .rect(.bounds)) -> some View {
        // Read here, in the caller's body, so observation re-renders the caller when it changes.
        let shown = model.statusPicker?.target == target
        return popover(
            isPresented: Binding(
                get: { shown },
                set: { shown in if !shown, model.statusPicker?.target == target { model.closeStatusPicker() } }
            ),
            attachmentAnchor: anchor,
            arrowEdge: .bottom
        ) {
            StatusPickerView().environment(model)
        }
    }
}
