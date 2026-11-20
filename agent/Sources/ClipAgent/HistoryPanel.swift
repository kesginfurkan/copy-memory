import AppKit
import ClipCore
import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query = "" { didSet { scheduleReload() } }
    @Published private(set) var items: [ClipItem] = []
    @Published var selection = 0
    @Published private(set) var error: String?

    let api: APIClient
    var onChoose: (ClipItem) -> Void = { _ in }
    private var reloadTask: Task<Void, Never>?

    init(api: APIClient) { self.api = api }

    func reset() {
        query = ""
        selection = 0
        reload()
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task {
            do {
                let result = try await api.list(query: query, limit: 200)
                guard !Task.isCancelled else { return }
                items = result
                selection = min(selection, max(0, items.count - 1))
                error = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Sunucuya ulaşılamıyor — `docker compose up -d` çalışıyor mu?"
            }
        }
    }

    private func scheduleReload() {
        selection = 0
        reload()
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
    }

    func choose(at index: Int) {
        guard items.indices.contains(index) else { return }
        onChoose(items[index])
    }

    func togglePin() {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        Task {
            try? await api.setPinned(id: item.id, pinned: !item.pinned)
            reload()
        }
    }

    func deleteSelected() {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        Task {
            try? await api.delete(id: item.id)
            reload()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Geçmişte ara…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
            }
            .padding(12)
            Divider()
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).padding()
            } else if model.items.isEmpty {
                Text(model.query.isEmpty ? "Henüz bir şey kopyalanmadı" : "Sonuç yok")
                    .foregroundStyle(.secondary).frame(maxHeight: .infinity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            HistoryRow(item: item, index: index, selected: index == model.selection,
                                       thumbnailURL: model.api.thumbnailURL(id: item.id))
                                .id(item.id)
                                .onTapGesture { model.selection = index; model.choose(at: index) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, newValue in
                    guard model.items.indices.contains(newValue) else { return }
                    proxy.scrollTo(model.items[newValue].id)
                }
            }
            Divider()
            Text("↩ yapıştır  ·  ⌘1–9 hızlı seç  ·  ⌘P sabitle  ·  ⌘⌫ sil  ·  esc kapat")
                .font(.caption).foregroundStyle(.secondary).padding(7)
        }
        .frame(width: 460, height: 540)
        .onAppear { searchFocused = true }
    }
}

private struct HistoryRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let thumbnailURL: URL

    private static let kindNames = ["text": "Metin", "rich": "Zengin", "image": "Görsel", "file": "Dosya", "other": "Diğer"]
    private static let kindIcons = ["text": "text.alignleft", "rich": "doc.richtext", "image": "photo", "file": "doc", "other": "square.dashed"]

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if item.hasThumbnail {
                    AsyncImage(url: thumbnailURL) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.1) }
                } else {
                    Image(systemName: Self.kindIcons[item.kind] ?? "square.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.trimmingCharacters(in: .whitespacesAndNewlines))
                    .lineLimit(2)
                    .font(.system(size: 12.5))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption) }
            if index < 9 { Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let date = Date(timeIntervalSince1970: item.lastUsedAt)
        let ago = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return [Self.kindNames[item.kind] ?? item.kind, item.sourceAppName, ago]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating, Maccy-style popup that appears near the mouse on the hotkey.
@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    let model: HistoryViewModel
    private let panel: KeyPanel
    private var keyMonitor: Any?
    private(set) var previousApp: NSRunningApplication?

    init(api: APIClient) {
        model = HistoryViewModel(api: api)
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered, defer: false
        )
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HistoryView(model: model))
        panel.delegate = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        model.reset()
        positionNearMouse()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = min(max(mouse.x - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(mouse.y - size.height - 12, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return event }
        switch event.keyCode {
        case 125: model.move(1); return nil            // ↓
        case 126: model.move(-1); return nil           // ↑
        case 36, 76: model.choose(at: model.selection); return nil  // return / enter
        case 53: hide(); return nil                    // esc
        default: break
        }
        guard event.modifierFlags.contains(.command) else { return event }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if chars == "p" { model.togglePin(); return nil }
        if event.keyCode == 51 { model.deleteSelected(); return nil }  // ⌘⌫
        if let n = Int(chars), (1...9).contains(n) { model.choose(at: n - 1); return nil }
        return event
    }
}
