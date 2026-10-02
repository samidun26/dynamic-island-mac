import AppKit
import NotchyCore
import SwiftUI
import UniformTypeIdentifiers

enum ShelfTab { case files, clipboard }

/// The shelf: files dropped on the notch, and clipboard history.
struct ShelfPage: View {
    let model: IslandModel

    var body: some View {
        let tab = model.shelfTab
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TabChip(title: "Files", count: model.shelf.files.count, on: tab == .files) { model.shelfTab = .files }
                TabChip(title: "Clipboard", count: model.clipboard.history.items.count, on: tab == .clipboard) { model.shelfTab = .clipboard }
                Spacer()
                if tab == .files, !model.shelf.files.isEmpty {
                    PillButton(title: "Clear", tint: .white.opacity(0.7)) { model.shelf.clear() }
                } else if tab == .clipboard, model.clipboard.history.items.contains(where: { !$0.pinned }) {
                    PillButton(title: "Clear", tint: .white.opacity(0.7)) { model.clipboard.clear() }
                }
            }
            Group {
                switch tab {
                case .files: FilesShelf(shelf: model.shelf, dropping: model.fileDragNear || model.dropTargeted, targeted: model.dropTargeted)
                case .clipboard: ClipboardShelf(clipboard: model.clipboard, enabled: model.settings.clipboardHistory)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct TabChip: View {
    let title: String
    let count: Int
    let on: Bool
    let action: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 { Text("\(count)").islandFont(10, .bold, digits: true).opacity(0.6) }
            }
            .islandFont(11.5, .semibold)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(.white.opacity(on ? 1 : 0.55))
            .background(RoundedRectangle(cornerRadius: theme.isRetro ? 0 : 20, style: .continuous).fill(.white.opacity(on ? 0.16 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Files

private struct FilesShelf: View {
    let shelf: ShelfModel
    /// Files are being dragged here; `targeted` once they are over the island.
    let dropping: Bool
    let targeted: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if dropping {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 22, weight: .semibold))
                    Text(targeted ? "Let go to keep it here" : "Drop on the island").islandFont(12, .semibold)
                }
                .foregroundStyle(.cyan.opacity(targeted ? 1 : 0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    let shape = RoundedRectangle(cornerRadius: theme.isRetro ? 0 : 14, style: .continuous)
                    shape.fill(.cyan.opacity(targeted ? 0.14 : 0.05))
                    shape.strokeBorder(.cyan.opacity(targeted ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            } else if shelf.files.isEmpty {
                Hint(symbol: "tray.and.arrow.down", text: "Drag files onto the notch to keep them here, then drag them out wherever you need them.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(shelf.files) { FileTile(file: $0, shelf: shelf) }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

private struct FileTile: View {
    let file: ShelfModel.File
    let shelf: ShelfModel
    @State private var hovering = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .interpolation(theme.isRetro ? .none : .high)
                .frame(width: 38, height: 38)
            Text(file.name)
                .islandFont(10, .medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 66)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.vertical, 4)
        .overlay(alignment: .topTrailing) {
            if hovering {
                IconButton(symbol: "xmark.circle.fill", label: "Remove \(file.name)", size: 13, box: 18, tint: .white.opacity(0.8)) {
                    shelf.remove(file.id)
                }
                .offset(x: 2, y: -4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { shelf.open(file) }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(file) }
            Button("Show in Finder") { shelf.reveal(file) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(file.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityAction(named: "Open") { shelf.open(file) }
    }
}

// MARK: Clipboard

private struct ClipboardShelf: View {
    let clipboard: ClipboardModel
    let enabled: Bool

    var body: some View {
        if !enabled {
            Hint(symbol: "doc.on.clipboard", text: "Clipboard history is off. Turn it on in Settings → Activities.")
        } else if clipboard.history.items.isEmpty {
            Hint(symbol: "doc.on.clipboard", text: "Copy something and it shows up here. Passwords from password managers are never kept.")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(clipboard.history.items) { ClipCard(item: $0, clipboard: clipboard) }
                }
            }
        }
    }
}

private struct ClipCard: View {
    let item: ClipHistory.Item
    let clipboard: ClipboardModel
    @State private var copied = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let kind = item.kind
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if case .color(let r, let g, let b) = kind {
                    RoundedRectangle(cornerRadius: theme.isRetro ? 0 : 3).fill(Color(red: r, green: g, blue: b)).frame(width: 12, height: 12)
                }
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .islandFont(11)
                    .lineLimit(3)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(copied ? "Copied" : label(kind))
                    .islandFont(9.5, .semibold)
                    .foregroundStyle(.white.opacity(copied ? 0.9 : 0.45))
                Spacer(minLength: 0)
                if case .link(let url) = kind {
                    IconButton(symbol: "arrow.up.right", label: "Open link", size: 10, box: 18, tint: .white.opacity(0.8)) { NSWorkspace.shared.open(url) }
                }
                IconButton(symbol: item.pinned ? "pin.fill" : "pin", label: item.pinned ? "Unpin" : "Pin", size: 10, box: 18,
                           tint: item.pinned ? .yellow : .white.opacity(0.6)) { clipboard.togglePin(item) }
            }
        }
        .padding(8)
        .frame(width: 132, height: 78, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: theme.isRetro ? 0 : 10, style: .continuous).fill(.white.opacity(0.08)))
        .overlay {
            if theme.isRetro { Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            clipboard.copy(item)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        }
        .contextMenu {
            Button("Copy") { clipboard.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Divider()
            Button("Remove") { clipboard.remove(item) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.text)
        .accessibilityAction(named: "Copy") { clipboard.copy(item) }
    }

    private func label(_ kind: ClipKind) -> String {
        switch kind {
        case .link: "Link"
        case .email: "Email"
        case .color: "Colour"
        case .text: "Click to copy"
        }
    }
}

private struct Hint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            Text(text).islandFont(11.5, .medium).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Files dragged onto the island land on the shelf.
struct ShelfDropTarget: ViewModifier {
    let model: IslandModel

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL], isTargeted: Binding(get: { model.dropTargeted }, set: { model.setDropTargeted($0) })) { providers in
            guard model.settings.shelfEnabled else { return false }
            for p in providers where p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.droppedOnShelf([url]) }
                }
            }
            return true
        }
    }
}
