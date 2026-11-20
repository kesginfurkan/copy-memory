import AppKit
import ClipCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = AgentConfig(environment: ProcessInfo.processInfo.environment)
    private lazy var api = APIClient(baseURL: config.apiURL)
    private lazy var monitor = ClipboardMonitor(config: config, api: api)
    private lazy var panel = HistoryPanelController(api: api)
    private var hotKey: HotKeyCenter?
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        panel.model.onChoose = { [weak self] item in self?.paste(item) }
        hotKey = HotKeyCenter(hotKey: config.hotKey) { [weak self] in
            let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "restore", let id = Int(arguments[2]) {
    // `copy-memory-agent restore <id>`: put a history item back on the pasteboard and exit.
    let config = AgentConfig(environment: ProcessInfo.processInfo.environment)
    Task {
        do {
            PasteboardIO.write(try await APIClient(baseURL: config.apiURL).payload(id: id), to: .general)
            exit(0)
        } catch {
            log("could not restore item \(id): \(error)")
            exit(1)
        }
    }
    dispatchMain()
} else if arguments.count > 1 {
    print("""
    usage: copy-memory-agent              run the menu bar agent
           copy-memory-agent restore <id> copy a history item back to the clipboard
    env:   COPY_MEMORY_API, COPY_MEMORY_HOTKEY, COPY_MEMORY_AUTO_PASTE,
           COPY_MEMORY_IGNORE_APPS, COPY_MEMORY_POLL_INTERVAL
    """)
    exit(arguments[1] == "--help" ? 0 : 2)
}

MainActor.assumeIsolated { self?.panel.toggle() }
        }
        if hotKey == nil { log("could not register hotkey (already used by another app?)") }
        setUpStatusItem()
        if config.autoPaste && !Paster.isTrusted { Paster.requestTrust() }
        log("copy-memory agent started → \(config.apiURL.absoluteString)")
    }

    private func paste(_ item: ClipItem) {
        let target = panel.previousApp
        Task {
            do {
                let items = try await api.payload(id: item.id)
                monitor.ignoreChange(PasteboardIO.write(items, to: .general))
                try? await api.use(id: item.id)
                panel.hide()
                target?.activate()
                if config.autoPaste && Paster.isTrusted {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    Paster.pasteCommandV()
                }
            } catch {
                log("could not restore item \(item.id): \(error)")
                NSSound.beep()
            }
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "copy-memory")
        let menu = NSMenu()
        menu.addItem(withTitle: "Geçmişi Aç", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Web Arayüzünü Aç", action: #selector(openWeb), keyEquivalent: "").target = self
        let pause = menu.addItem(withTitle: "Kaydı Duraklat", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pauseItem = pause
        menu.addItem(.separator())
        menu.addItem(withTitle: "Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openHistory() { panel.show() }

    @objc private func openWeb() { NSWorkspace.shared.open(config.apiURL) }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        pauseItem?.title = monitor.isPaused ? "Kayda Devam Et" : "Kaydı Duraklat"
        statusItem?.button?.appearsDisabled = monitor.isPaused
    }
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "restore", let id = Int(arguments[2]) {
    // `copy-memory-agent restore <id>`: put a history item back on the pasteboard and exit.
    let config = AgentConfig(environment: ProcessInfo.processInfo.environment)
    Task {
        do {
            PasteboardIO.write(try await APIClient(baseURL: config.apiURL).payload(id: id), to: .general)
            exit(0)
        } catch {
            log("could not restore item \(id): \(error)")
            exit(1)
        }
    }
    dispatchMain()
} else if arguments.count > 1 {
    print("""
    usage: copy-memory-agent              run the menu bar agent
           copy-memory-agent restore <id> copy a history item back to the clipboard
    env:   COPY_MEMORY_API, COPY_MEMORY_HOTKEY, COPY_MEMORY_AUTO_PASTE,
           COPY_MEMORY_IGNORE_APPS, COPY_MEMORY_POLL_INTERVAL
    """)
    exit(arguments[1] == "--help" ? 0 : 2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
