import Foundation

/// A global shortcut expressed with Carbon key codes / modifier masks
/// (kept free of Carbon imports so it can be unit tested).
public struct HotKey: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public static let cmd: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ANSI virtual key codes (kVK_ANSI_*).
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "`": 50,
    ]

    /// Parses strings such as `cmd+shift+v` or `⌥⌘V`-style `opt+cmd+v`.
    public static func parse(_ string: String) -> HotKey? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for raw in string.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "⌘": modifiers |= cmd
            case "shift", "⇧": modifiers |= shift
            case "opt", "option", "alt", "⌥": modifiers |= option
            case "ctrl", "control", "⌃": modifiers |= control
            default:
                guard key == nil, let code = keyCodes[part] else { return nil }
                key = code
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return HotKey(keyCode: key, modifiers: modifiers)
    }

    public static let defaultHotKey = HotKey(keyCode: 9, modifiers: cmd | shift)  // ⌘⇧V
}

public struct AgentConfig: Sendable {
    public var apiURL: URL
    public var hotKey: HotKey
    public var autoPaste: Bool
    public var ignoredApps: Set<String>
    public var pollInterval: TimeInterval

    /// Password managers are skipped even if they forget to mark their copies as concealed.
    public static let defaultIgnoredApps: Set<String> = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "in.sinew.Enpass-Desktop",
    ]

    /// Reads `COPY_MEMORY_*` environment variables, falling back to defaults.
    public init(environment env: [String: String]) {
        apiURL = env["COPY_MEMORY_API"].flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:5050")!
        hotKey = env["COPY_MEMORY_HOTKEY"].flatMap(HotKey.parse) ?? .defaultHotKey
        autoPaste = !["0", "false", "no"].contains(env["COPY_MEMORY_AUTO_PASTE"]?.lowercased() ?? "")
        let extra = (env["COPY_MEMORY_IGNORE_APPS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        ignoredApps = Self.defaultIgnoredApps.union(extra)
        pollInterval = env["COPY_MEMORY_POLL_INTERVAL"].flatMap(TimeInterval.init).map { max(0.1, $0) } ?? 0.5
    }
}
