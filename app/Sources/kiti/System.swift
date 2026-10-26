import AppKit
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Speech

final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String, lang: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        let pref = lang.hasPrefix("zh") ? AppSettings.shared.voiceZH : (lang == "en-US" ? AppSettings.shared.voiceEN : "")
        u.voice = (pref.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: pref))
            ?? AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: String(lang.prefix(2)))
        // AVSpeechUtterance rate is 0...1 with 0.5 default; map the 0.6–1.4 choices onto it.
        u.rate = Float(min(max(0.5 * AppSettings.shared.speechRate, 0.25), 0.7))
        synth.speak(u)
    }

    func speakAuto(_ text: String) {
        if LocalDictionary.isChinese(text) { speak(text, lang: "zh-CN") }
        else if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { speak(text, lang: "ja-JP") }
        else if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { speak(text, lang: "ko-KR") }
        else { speak(text, lang: "en-US") }
    }

    /// Installed voices for a language prefix ("en" / "zh"), best quality first.
    static func voices(_ prefix: String) -> [(id: String, name: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { v in
                let q = v.quality == .premium ? "（高级）" : v.quality == .enhanced ? "（增强）" : ""
                return (v.identifier, "\(v.name)\(q) · \(v.language)")
            }
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}

// MARK: - Global hot keys (Carbon; works without extra permissions)

final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(_ items: [(Shortcut, () -> Void)]) {
        for r in refs { if let r = r { UnregisterEventHotKey(r) } }
        refs.removeAll(); handlers.removeAll()
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { HotKeys.shared.handlers[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        for (i, item) in items.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x6B697469), id: id)   // 'kiti'
            RegisterEventHotKey(item.0.keyCode, item.0.mods, hkID, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
            handlers[id] = item.1
        }
    }
}

extension HotKeys {
    private static var returnRef: EventHotKeyRef?

    /// Temporarily claims the bare Return key (so it does not reach the frontmost app); pass nil to release.
    func setReturnHook(_ f: (() -> Void)?) {
        if let r = HotKeys.returnRef { UnregisterEventHotKey(r); HotKeys.returnRef = nil }
        handlers[99] = nil
        guard let f = f else { return }
        handlers[99] = f
        RegisterEventHotKey(UInt32(kVK_Return), 0, EventHotKeyID(signature: OSType(0x6B697469), id: 99), GetApplicationEventTarget(), 0, &HotKeys.returnRef)
    }
}

// MARK: - Selection reading

enum SelectionReader {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Selected text through the Accessibility API; nil when the app does not expose it.
    static func viaAX() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success,
              let s = sel as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Fallback: simulate ⌘C, read the pasteboard, then put the previous contents back.
    static func viaCopy(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            var text: String?
            if pb.changeCount != before { text = pb.string(forType: .string) }
            if pb.changeCount != before {
                pb.clearContents()
                for item in saved {
                    let n = NSPasteboardItem()
                    for (t, d) in item { n.setData(d, forType: t) }
                    pb.writeObjects([n])
                }
            }
            completion(text)
        }
    }

    static func read(completion: @escaping (String?) -> Void) {
        if let s = viaAX() { completion(s); return }
        viaCopy(completion: completion)
    }
}

/// Watches the mouse globally and reports a finished selection gesture.
final class SelectionPicker {
    var onText: ((String, NSPoint) -> Void)?
    var onDismissGesture: (() -> Void)?
    private var monitors: [Any] = []
    private var downPoint = NSPoint.zero
    private var downTime = Date()
    private var lastText = ""

    func start() {
        stop()
        Self.started = Date()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            self?.downPoint = NSEvent.mouseLocation; self?.downTime = Date()
            self?.onDismissGesture?()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.onDismissGesture?()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] e in
            self?.mouseUp(e)
        }) { monitors.append(m) }
    }

    func stop() { monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll() }

    /// Last few selection gestures and what became of them — shown by the menu's 取词诊断.
    static var diag: [String] = []
    static var started: Date?
    private static func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "H:mm:ss"
        diag.append("\(f.string(from: Date()))  \(s)")
        if diag.count > 8 { diag.removeFirst() }
    }

    private func mouseUp(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        let dragged = hypot(p.x - downPoint.x, p.y - downPoint.y) > 6
        let multi = e.clickCount >= 2
        let shift = e.modifierFlags.contains(.shift)
        guard dragged || multi || shift else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let who = app?.localizedName ?? "?"
        let gesture = multi ? "双击" : dragged ? "拖选" : "Shift+点击"
        if let bid = app?.bundleIdentifier, AppSettings.shared.blacklistSet.contains(bid) { Self.note("\(who) \(gesture)：在黑名单里，已忽略"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            let finish: (String?, String) -> Void = { text, via in
                guard let self = self else { return }
                guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { Self.note("\(who) \(gesture)：没读到选中文字（辅助功能和 ⌘C 都失败）"); return }
                guard t.count <= 3000, t.rangeOfCharacter(from: .letters) != nil else { Self.note("\(who) \(gesture)：读到 \(t.count) 字但被过滤（过长或不含字母）"); return }
                Self.note("\(who) \(gesture)：\(via)读到 \(t.count) 字，已弹出")
                self.onText?(t, p)
            }
            if let s = SelectionReader.viaAX() { finish(s, "辅助功能"); return }
            SelectionReader.viaCopy { finish($0, "⌘C ") }
        }
    }
}
