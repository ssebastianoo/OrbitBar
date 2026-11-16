import SwiftUI

extension Color {
    /// `#8b5cf6` or `8b5cf6`; gray when it can't be read.
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { self = .gray; return }
        self = Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// The status glyph Orbit uses: an empty ring for to do, a half ring for in progress, a check for done.
struct StatusIcon: View {
    var status: TaskStatus?
    var size: CGFloat = 14

    var body: some View {
        let color = Color(hex: status?.color ?? "#9ca3af")
        ZStack {
            switch status?.category {
            case "completed":
                Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(color)
            case "cancelled", "duplicate":
                Image(systemName: "xmark.circle.fill").resizable().foregroundStyle(color)
            case "started":
                Circle().strokeBorder(color, lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.5).fill(color).rotationEffect(.degrees(-90)).padding(3)
            default:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: status == nil ? [2, 2] : []))
            }
        }
        .frame(width: size, height: size)
    }
}

struct PriorityIcon: View {
    var priority: Priority

    var body: some View {
        switch priority {
        case .none:
            EmptyView()
        case .urgent:
            Image(systemName: "exclamationmark.square.fill").foregroundStyle(.orange)
        case .low, .medium, .high:
            let filled = priority == .low ? 1 : priority == .medium ? 2 : 3
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < filled ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                        .frame(width: 3, height: CGFloat(5 + index * 3))
                }
            }
            .frame(width: 14, height: 12, alignment: .bottom)
        }
    }
}

struct Avatar: View {
    @Environment(AppModel.self) private var model
    var member: Member?
    var size: CGFloat = 18
    @State private var image: NSImage?

    var body: some View {
        let name = member?.displayName ?? "?"
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let url = OrbitClient.resolve(member?.avatarUrl, server: model.client?.server)
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                fallback(initials)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .help(name)
        .task(id: url) { await load(url) }
    }

    /// Orbit's avatar URLs are relative `/api/…` paths that need the session, so `AsyncImage` can't load them.
    private func load(_ url: URL?) async {
        guard let url else { image = nil; return }
        if let cached = ImageCache.images.object(forKey: url as NSURL) { image = cached; return }
        image = nil
        do {
            let data: Data
            if let client = model.client { data = try await client.fileData(url) } else { data = try await URLSession.shared.data(from: url).0 }
            guard let loaded = NSImage(data: data) else { return }
            ImageCache.images.setObject(loaded, forKey: url as NSURL)
            image = loaded
        } catch {}
    }

    private func fallback(_ initials: String) -> some View {
        let seed = (member?.userId ?? "").unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(seed % 360) / 360
        return ZStack {
            Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.75))
            Text(initials.isEmpty ? "?" : initials).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

/// Orbit's logo (`apps/web/public/logo.svg`): a pink ring of pixel blocks on an 11×11 grid, over a dark copy of
/// itself shifted one block down and right.
struct OrbitLogo: View {
    nonisolated static let blocks: [CGRect] = [
        CGRect(x: 0, y: 2, width: 2, height: 6), CGRect(x: 2, y: 0, width: 6, height: 2),
        CGRect(x: 8, y: 2, width: 2, height: 6), CGRect(x: 2, y: 8, width: 6, height: 2),
    ]

    var body: some View {
        ZStack {
            Blocks(offset: 1).fill(Color(hex: "742f4d"))
            Blocks(offset: 0).fill(Color(hex: "f2458f"))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private struct Blocks: Shape {
        var offset: CGFloat
        func path(in rect: CGRect) -> Path {
            let unit = min(rect.width, rect.height) / 11
            var path = Path()
            for block in OrbitLogo.blocks {
                path.addRect(CGRect(x: rect.minX + (block.minX + offset) * unit, y: rect.minY + (block.minY + offset) * unit,
                                    width: block.width * unit, height: block.height * unit))
            }
            return path
        }
    }

    /// The menu bar icon, as a template image so it follows the menu bar's color: the ring solid, its shadow faded.
    /// Blocks are 1.5pt, so every edge lands on a pixel on Retina screens.
    static func templateImage() -> NSImage {
        let unit: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: true) { rect in
            func scaled(_ block: CGRect, _ offset: CGFloat) -> NSRect {
                NSRect(x: (block.minX + offset) * unit, y: (block.minY + offset) * unit, width: block.width * unit, height: block.height * unit)
            }
            let ring = NSBezierPath()
            blocks.forEach { ring.appendRect(scaled($0, 0)) }

            NSGraphicsContext.saveGraphicsState()
            let outsideRing = NSBezierPath(rect: rect)
            outsideRing.append(ring)
            outsideRing.windingRule = .evenOdd
            outsideRing.addClip()
            NSColor.black.withAlphaComponent(0.45).setFill()
            blocks.forEach { scaled($0, 1).fill() }
            NSGraphicsContext.restoreGraphicsState()

            NSColor.black.setFill()
            ring.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Orbit"
        return image
    }
}

struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.12)))
    }
}

struct Hint: View {
    var keys: String
    var title: String
    var body: some View {
        HStack(spacing: 3) {
            KeyCap(text: keys)
            Text(title)
        }
    }
}

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }
}

enum DueFormat {
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }

    static func isOverdue(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        date < now && !calendar.isDateInToday(date)
    }
}
