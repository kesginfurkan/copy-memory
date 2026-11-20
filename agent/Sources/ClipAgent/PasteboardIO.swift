import AppKit
import ApplicationServices
import ClipCore

enum PasteboardIO {
    /// Captures every representation of every item currently on the pasteboard.
    static func read(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            var reps: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { reps[type.rawValue] = data }
            }
            return reps.isEmpty ? nil : reps
        }
    }

    /// Restores a snapshot exactly as it was captured. Returns the new change count.
    @discardableResult
    static func write(_ items: [[String: Data]], to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let pbItems = items.map { reps -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in reps { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.writeObjects(pbItems)
        return pasteboard.changeCount
    }

    static func thumbnail(from pasteboard: NSPasteboard, maxSide: CGFloat = 480) -> Data? {
        guard let image = NSImage(pasteboard: pasteboard), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Sends ⌘V to the frontmost app (requires Accessibility permission).
    static func pasteCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
