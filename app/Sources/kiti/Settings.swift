import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import Security

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32      // Carbon modifier mask
    var label: String     // key label, e.g. "D", "␣"

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}

enum Provider: String, CaseIterable, Identifiable {
    case magpie, google, deepl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .magpie: return "Magpie（本机网关）"
        case .google: return "Google 翻译"
        case .deepl: return "DeepL"
        }
    }
}

struct Lang {
    let code, zh, short, english, google, deepl: String
    static let all: [Lang] = [
        Lang(code: "en", zh: "英语", short: "英", english: "English", google: "en", deepl: "EN-US"),
        Lang(code: "ja", zh: "日语", short: "日", english: "Japanese", google: "ja", deepl: "JA"),
        Lang(code: "ko", zh: "韩语", short: "韩", english: "Korean", google: "ko", deepl: "KO"),
        Lang(code: "fr", zh: "法语", short: "法", english: "French", google: "fr", deepl: "FR"),
        Lang(code: "de", zh: "德语", short: "德", english: "German", google: "de", deepl: "DE"),
        Lang(code: "es", zh: "西班牙语", short: "西", english: "Spanish", google: "es", deepl: "ES"),
        Lang(code: "ru", zh: "俄语", short: "俄", english: "Russian", google: "ru", deepl: "RU"),
    ]
    static let chinese = Lang(code: "zh", zh: "中文", short: "中", english: "Simplified Chinese", google: "zh-CN", deepl: "ZH")
    static func of(_ code: String) -> Lang { code == "zh" ? chinese : (all.first { $0.code == code } ?? all[0]) }
}

enum Direction: String, CaseIterable, Identifiable {
    case enZh, zhEn, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .enZh: return "\(Lang.of(AppSettings.shared.otherLang).zh) → 中文"
        case .zhEn: return "中文 → \(Lang.of(AppSettings.shared.otherLang).zh)"
        case .auto: return "自动检测"
        }
    }
}

enum Keychain {
    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.kiti.mac",
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.kiti.mac", kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var autoPick: Bool { didSet { d.set(autoPick, forKey: "autoPick"); onChange?() } }
    @Published var autoSentence: Bool { didSet { d.set(autoSentence, forKey: "autoSentence") } }
    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var otherLang: String { didSet { d.set(otherLang, forKey: "otherLang") } }
    @Published var voiceEN: String { didSet { d.set(voiceEN, forKey: "voiceEN") } }
    @Published var voiceZH: String { didSet { d.set(voiceZH, forKey: "voiceZH") } }
    @Published var direction: Direction { didSet { d.set(direction.rawValue, forKey: "direction2") } }
    @Published var magpieURL: String { didSet { d.set(magpieURL, forKey: "magpieURL") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var proxyOn: Bool { didSet { d.set(proxyOn, forKey: "proxyOn") } }
    @Published var proxyType: String { didSet { d.set(proxyType, forKey: "proxyType") } }
    @Published var proxyHost: String { didSet { d.set(proxyHost, forKey: "proxyHost") } }
    @Published var googleKey: String { didSet { Keychain.set("google", googleKey) } }
    @Published var deeplKey: String { didSet { Keychain.set("deepl", deeplKey) } }
    @Published var llmKey: String { didSet { Keychain.set("llm", llmKey) } }
    @Published var llmPrompt: String { didSet { d.set(llmPrompt, forKey: "llmPrompt") } }
    @Published var llmTemp: Double { didSet { d.set(llmTemp, forKey: "llmTemp") } }
    @Published var llmProxy: Bool { didSet { d.set(llmProxy, forKey: "llmProxy") } }
    @Published var uiScale: Double { didSet { d.set(uiScale, forKey: "uiScale") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    @Published var blacklist: String { didSet { d.set(blacklist, forKey: "blacklist") } }
    @Published var launchAtLogin: Bool {
        didSet {
            d.set(launchAtLogin, forKey: "launchAtLogin")
            if #available(macOS 13.0, *) {
                do { launchAtLogin ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {}
            }
        }
    }
    @Published var scToggle: Shortcut { didSet { save("scToggle", scToggle); onShortcuts?() } }
    @Published var scMain: Shortcut { didSet { save("scMain", scMain); onShortcuts?() } }
    @Published var scClip: Shortcut { didSet { save("scClip", scClip); onShortcuts?() } }
    @Published var quitOnClose: Bool { didSet { d.set(quitOnClose, forKey: "quitOnClose") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock"); Task { @MainActor in DockPresence.apply() } } }
    @Published var scQuick: Shortcut { didSet { save("scQuick", scQuick); onShortcuts?() } }
    @Published var scSpeak: Shortcut { didSet { save("scSpeak", scSpeak); onShortcuts?() } }

    var onChange: (() -> Void)?
    var onShortcuts: (() -> Void)?

    private func save(_ k: String, _ s: Shortcut) { if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: k) } }
    private func load(_ k: String, _ def: Shortcut) -> Shortcut {
        if let data = d.data(forKey: k), let s = try? JSONDecoder().decode(Shortcut.self, from: data) { return s }
        return def
    }

    init() {
        autoPick = d.object(forKey: "autoPick") as? Bool ?? true
        autoSentence = d.bool(forKey: "autoSentence")
        provider = Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .magpie
        direction = Direction(rawValue: d.string(forKey: "direction2") ?? "") ?? .auto
        otherLang = d.string(forKey: "otherLang") ?? "en"
        voiceEN = d.string(forKey: "voiceEN") ?? ""
        voiceZH = d.string(forKey: "voiceZH") ?? ""
        magpieURL = d.string(forKey: "magpieURL") ?? "http://127.0.0.1:3425"
        model = d.string(forKey: "model") ?? "workbuddy/glm-5.3-flash"
        proxyOn = d.bool(forKey: "proxyOn")
        proxyType = d.string(forKey: "proxyType") ?? "SOCKS5"
        proxyHost = d.string(forKey: "proxyHost") ?? "127.0.0.1:7890"
        googleKey = Keychain.get("google")
        deeplKey = Keychain.get("deepl")
        llmKey = Keychain.get("llm")
        llmPrompt = d.string(forKey: "llmPrompt") ?? ""
        llmTemp = d.object(forKey: "llmTemp") as? Double ?? 0.2
        llmProxy = d.bool(forKey: "llmProxy")
        // Revision 3: displayed 100% is 90% of the original 1.3 baseline.
        // Snapshot argument overrides never migrate persisted preferences.
        let scaleOverride = d.volatileDomain(forName: UserDefaults.argumentDomain)["uiScale"] != nil
        if scaleOverride {
            uiScale = UIScale.nearest(d.object(forKey: "uiScale") as? Double ?? UIScale.standard)
        } else {
            let revision = d.integer(forKey: "uiScaleBaselineRevision")
            let previousDefault = revision < 2 ? 1.3 : (revision < 3 ? 1.04 : UIScale.standard)
            let saved = d.object(forKey: "uiScale") as? Double ?? previousDefault
            let corrected = revision < 2 ? saved * 0.9 : (revision < 3 ? saved * (0.9 / 0.8) : saved)
            let scale = UIScale.nearest(corrected)
            uiScale = scale
            if revision < 3 {
                d.set(scale, forKey: "uiScale")
                d.set(3, forKey: "uiScaleBaselineRevision")
            }
        }
        let sr = d.object(forKey: "speechRate") as? Double ?? 1.0
        speechRate = [0.6, 0.8, 1.0, 1.2, 1.4].min { abs($0 - sr) < abs($1 - sr) } ?? 1.0
        blacklist = d.string(forKey: "blacklist") ?? "com.apple.Terminal\ncom.googlecode.iterm2"
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        quitOnClose = d.bool(forKey: "quitOnClose")
        showInDock = d.bool(forKey: "showInDock")
        let opt = UInt32(optionKey)
        scToggle = Shortcut(keyCode: 2, mods: opt, label: "D")
        scMain = Shortcut(keyCode: 49, mods: opt, label: "␣")
        scClip = Shortcut(keyCode: 17, mods: opt | UInt32(shiftKey), label: "T")
        scSpeak = Shortcut(keyCode: 1, mods: opt, label: "S")
        scQuick = Shortcut(keyCode: 12, mods: opt, label: "Q")
        scToggle = load("scToggle", scToggle)
        scMain = load("scMain", scMain)
        scClip = load("scClip", scClip)
        scSpeak = load("scSpeak", scSpeak)
        scQuick = load("scQuick", scQuick)
    }

    var blacklistSet: Set<String> {
        Set(blacklist.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// The model name shown in the UI (drops the channel prefix).
    var modelShort: String { model.split(separator: "/").last.map(String.init) ?? model }
}
