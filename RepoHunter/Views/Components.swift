import SwiftUI
import AppKit

/// Remote image with on-disk caching (used for owner avatars so they work offline).
struct CachedAvatar: View {
    let url: URL?
    var size: CGFloat = 40

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "app.dashed").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        let key = "avatar|\(url.absoluteString)"
        if let data = DiskCache.shared.loadData(key: key), let img = NSImage(data: data) {
            image = img
            return
        }
        // Ask GitHub for a smaller rendition.
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "s", value: String(Int(size * 3))))
        comps?.queryItems = items
        guard let final = comps?.url,
              let data = try? await GitHubAPI.shared.fetchData(final),
              let img = NSImage(data: data) else { return }
        DiskCache.shared.storeData(data, key: key)
        image = img
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
        .foregroundStyle(tint)
    }
}

struct Banner: View {
    let message: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var onDismiss: (() -> Void)?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.link)
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.3)))
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            if let retry {
                Button("重试", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
