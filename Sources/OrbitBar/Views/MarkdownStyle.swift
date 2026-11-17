import AppKit
import MarkdownUI
import SwiftUI

/// A compact Markdown theme in the system font, sized for the menu bar panel.
extension Theme {
    static let orbit = Theme.basic
        .text {
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.primary.opacity(0.08))
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(1.1), bottom: .em(0.45))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.45))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.4))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.9), bottom: .em(0.35))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: .em(0.2))
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .foregroundStyle(configuration.isCompleted ? Color.accentColor : Color.secondary)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.leading, length: .em(0.8))
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        .thematicBreak {
            Divider().markdownMargin(top: .em(1), bottom: .em(1))
        }
}

/// Loads description images. Orbit's own files (`/api/…` attachment URLs) need the session, so
/// requests to the signed-in server carry the bearer token; other hosts never see it. Images on other
/// sites go through the image proxy, or wait for a click when there is none.
struct AuthorizedImageProvider: ImageProvider {
    var client: OrbitClient?

    func makeImage(url: URL?) -> some View {
        AuthorizedImage(url: url, client: client)
    }
}

@MainActor
enum ImageCache {
    static let images = NSCache<NSURL, NSImage>()
}

struct AuthorizedImage: View {
    var url: URL?
    var client: OrbitClient?
    @State private var image: NSImage?
    @State private var failed = false
    @State private var blocked = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: 360, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture(count: 2) { if let url, OrbitClient.isWeb(url) { NSWorkspace.shared.open(url) } }
                    .help("Double-click to open")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: failed || blocked ? 36 : 120)
                    .overlay {
                        if blocked {
                            HStack(spacing: 6) {
                                Label(url?.host ?? "External image", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                                Button("Load Image") { Task { await load(direct: true) } }
                                    .controlSize(.small)
                                    .help("Loads the image straight from \(url?.host ?? "its site"), which then sees your address")
                            }
                        } else if failed {
                            Label("Image unavailable", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .task(id: url) { await load() }
    }

    private func load(direct: Bool = false) async {
        blocked = false
        guard let url, OrbitClient.isWeb(url), let client else { failed = true; return }
        if let cached = ImageCache.images.object(forKey: url as NSURL) { image = cached; return }
        do {
            let data = try await client.fileData(url, direct: direct)
            guard let loaded = NSImage(data: data) else { failed = true; return }
            ImageCache.images.setObject(loaded, forKey: url as NSURL)
            image = loaded
        } catch OrbitError.externalImageBlocked {
            blocked = true
        } catch {
            failed = true
        }
    }
}

/// Wraps chips (or anything) onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
