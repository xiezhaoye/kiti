import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    static let designSize = NSSize(width: 700, height: 600)
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let k = CGFloat(AppSettings.shared.uiScale)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: designSize.width * k, height: designSize.height * k),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "设置"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ScaleFill { SettingsView() })
            w.center()
            ScaleSync.bind(w, base: designSize, fixed: true)
            window = w
        }
        DockPresence.windowOpened()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ShortcutField: View {
    @Binding var sc: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "按下新的快捷键…" : sc.display).font(.system(size: 12.5)).foregroundStyle(recording ? T.accent : T.fg)
                .padding(.horizontal, 9).frame(minWidth: 70, minHeight: 24)
                .background(T.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(recording ? T.accent : T.sep, lineWidth: recording ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = Shortcut.carbonMods(e.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }
            var label = (e.charactersIgnoringModifiers ?? "?").uppercased()
            switch e.keyCode { case 49: label = "␣"; case 36: label = "↩"; case 48: label = "⇥"; case 51: label = "⌫"; default: break }
            sc = Shortcut(keyCode: UInt32(e.keyCode), mods: mods, label: label)
            stop()
            return nil
        }
    }
    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

struct SGroup<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.fg3).padding(.leading, 3).padding(.top, 14)
            VStack(spacing: 0) { content }
                .background(T.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.sep, lineWidth: 0.5))
        }
    }
}

struct SRow<R: View>: View {
    let label: String
    var hint: String? = nil
    var first = false
    @ViewBuilder var right: R
    var body: some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(T.sep).frame(height: 0.5).padding(.leading, 14) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 13)).foregroundStyle(T.fg)
                    if let h = hint { Text(h).font(.system(size: 11)).foregroundStyle(T.fg3).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                right.foregroundStyle(T.fg2)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
        }
    }
}

struct KeysBox: View {
    @Binding var sc: Shortcut
    var body: some View {
        ShortcutField(sc: $sc)
    }
}

struct KField: View {
    let text: Binding<String>
    var secure = false
    var width: CGFloat = 190
    var body: some View {
        Group { if secure { SecureField("", text: text) } else { TextField("", text: text) } }
            .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).multilineTextAlignment(.trailing)
            .padding(.horizontal, 8).frame(width: width, height: 24)
            .background(T.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(T.sep, lineWidth: 0.5))
    }
}

struct KPopup<V: Hashable>: View {
    @Binding var sel: V
    let items: [(V, String)]
    var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in Button(it.1) { sel = it.0 } }
        } label: {
            Text(items.first { $0.0 == sel }?.1 ?? "")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .padding(.horizontal, 9).frame(height: 24)
        .background(T.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct KSwitch: View {
    @Binding var on: Bool
    var body: some View {
        Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().tint(T.accent)
    }
}

struct SettingsView: View {
    @ObservedObject var s = AppSettings.shared
    @State private var tab = SettingsView.startTab
    @State private var syncPath = HistoryStore.shared.syncFolder
    @State private var syncMsg = ""
    static var startTab = 0
    func setTab(_ i: Int) { SettingsView.startTab = i }
    @State private var trusted = SelectionReader.trusted
    @State private var proxyMsg = ""
    @State private var models: [String] = []
    @State private var llmMsg = ""
    @State private var googleMsg = ""
    @State private var deeplMsg = ""

    private var pageTitle: String { ["快捷键", "大模型", "翻译 API", "朗读", "通用"][tab] }
    private var pageDescription: String {
        ["管理全局快捷键、取词行为与辅助功能权限。", "选择默认翻译服务，配置模型与翻译方向。",
         "配置翻译 API 和网络代理。", "选择朗读声音，调整语速并试听。", "管理启动行为、界面大小与历史同步。"][tab]
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("偏好设置").font(.system(size: 10)).foregroundStyle(T.fg3)
                    .padding(.horizontal, 12).padding(.bottom, 12)
                VStack(spacing: 4) {
                    tabBtn(4, "gearshape", "通用"); tabBtn(0, "command", "快捷键"); tabBtn(1, "sparkles", "大模型")
                    tabBtn(2, "globe", "翻译 API"); tabBtn(3, "speaker.wave.2", "朗读")
                }
                Spacer()
                Text("kiti · 本机设置").font(.system(size: 10)).foregroundStyle(T.fg3)
                    .padding(.horizontal, 12).frame(height: T.footerHeight)
            }
            .padding(.horizontal, 9).padding(.top, 48).frame(width: 146).background(T.win)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(pageTitle).font(.system(size: 20, weight: .semibold))
                    Text(pageDescription).font(.system(size: 11.5)).foregroundStyle(T.fg2)
                }
                .padding(.horizontal, 22).padding(.top, 36).padding(.bottom, 17)
                Sep()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        switch tab {
                        case 0: keys
                        case 1: llm
                        case 2: service
                        case 3: voice
                        default: general
                        }
                    }.padding(.horizontal, 22).padding(.top, 2).padding(.bottom, 24)
                }
            }.frame(maxWidth: .infinity).background(T.win)
        }
        .frame(width: SettingsWindow.designSize.width, height: SettingsWindow.designSize.height)
        .foregroundStyle(T.fg).ignoresSafeArea()
    }

    func tabBtn(_ i: Int, _ sym: String, _ title: String) -> some View {
        Button { tab = i } label: {
            HStack(spacing: 9) {
                Image(systemName: sym).font(.system(size: 13)).frame(width: 17)
                Text(title).font(.system(size: 12.5, weight: tab == i ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tab == i ? T.accent : T.fg2)
            .padding(.horizontal, 10).frame(height: 32)
            .background(tab == i ? T.fill2 : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).focusable(false).accessibilityAddTraits(tab == i ? .isSelected : [])
    }

    @ViewBuilder var keys: some View {
        SGroup(title: "快捷键") {
            SRow(label: "自动取词开关", hint: "全局生效，菜单栏图标同步变化", first: true) { KeysBox(sc: $s.scToggle) }
            SRow(label: "打开主窗口") { KeysBox(sc: $s.scMain) }
            SRow(label: "快速查询", hint: "弹出搜索框，回车后在主窗口显示结果") { KeysBox(sc: $s.scQuick) }
            SRow(label: "翻译剪贴板内容") { KeysBox(sc: $s.scClip) }
            SRow(label: "朗读选中文字") { KeysBox(sc: $s.scSpeak) }
        }
        SGroup(title: "取词行为") {
            SRow(label: "自动取词", hint: "关闭后选中文字不再弹出", first: true) { KSwitch(on: $s.autoPick) }
            SRow(label: "选中句子自动翻译", hint: "关闭时先显示“翻译”胶囊，点击后才请求") { KSwitch(on: $s.autoSentence) }
            SRow(label: "在这些 App 中不取词", hint: "Bundle ID，每行一个") {
                TextEditor(text: $s.blacklist).font(.system(size: 11.5, design: .monospaced)).scrollContentBackground(.hidden)
                    .frame(width: 220, height: 50).background(T.field, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(T.sep, lineWidth: 0.5))
            }
        }
        SGroup(title: "权限") {
            SRow(label: "辅助功能", hint: "用来读取选中文字", first: true) {
                HStack(spacing: 8) {
                    if trusted { HStack(spacing: 6) { Circle().fill(T.ok).frame(width: 7, height: 7); Text("已允许").foregroundStyle(T.ok) } }
                    else { KBtn(title: "去授权", primary: true) { SelectionReader.requestTrust() } }
                    KBtn(title: "刷新") { trusted = SelectionReader.trusted }
                }
            }
        }
    }

    @ViewBuilder var llm: some View {
        SGroup(title: "默认翻译服务") {
            SRow(label: "默认服务", hint: "句子和短文用它翻译，单词始终先查系统词典", first: true) { KPopup(sel: $s.provider, items: Provider.allCases.map { ($0, $0.title) }) }
            SRow(label: "外语") { KPopup(sel: $s.otherLang, items: Lang.all.map { ($0.code, $0.zh) }) }
            SRow(label: "默认方向") { KPopup(sel: $s.direction, items: Direction.allCases.map { ($0, $0.title) }) }
        }
        SGroup(title: "大模型（OpenAI 兼容接口）") {
            SRow(label: "接口地址", hint: "本机 Magpie 或任意 OpenAI 兼容服务", first: true) { KField(text: $s.magpieURL) }
            SRow(label: "API Key", hint: "本机网关可留空；保存在 macOS 钥匙串") { KField(text: $s.llmKey, secure: true) }
            SRow(label: "模型", hint: "选 flash / mini 类更快") {
                HStack(spacing: 6) {
                    KField(text: $s.model, width: 150)
                    Menu {
                        ForEach(models.isEmpty ? ["workbuddy/glm-5.3-flash", "workbuddy/deepseek-v4.1-flash", "auto/gemini-3.8-flash"] : models, id: \.self) { m in Button(m) { s.model = m } }
                    } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    KBtn(title: "获取列表") { loadModels() }
                }
            }
            SRow(label: "温度", hint: "越低译文越稳定") {
                HStack(spacing: 8) {
                    Slider(value: $s.llmTemp, in: 0...1, step: 0.1).frame(width: 150).tint(T.accent)
                    Text(String(format: "%.1f", s.llmTemp)).monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
            SRow(label: "远程接口走代理", hint: "本机地址始终直连；代理在“翻译 API”页设置") { KSwitch(on: $s.llmProxy) }
            SRow(label: "测试") {
                HStack(spacing: 8) {
                    if !llmMsg.isEmpty { Text(llmMsg).font(.system(size: 12)).foregroundStyle(T.fg2).lineLimit(2).frame(maxWidth: 190, alignment: .trailing) }
                    KBtn(title: "测试连接") { Task { llmMsg = "测试中…"; llmMsg = await Translator.shared.test(.magpie) } }
                }
            }
        }
        SGroup(title: "提示词") {
            SRow(label: "系统提示词", hint: "留空用内置提示词；可用 {target} 代表目标语言", first: true) {
                TextEditor(text: $s.llmPrompt).font(.system(size: 11.5)).scrollContentBackground(.hidden)
                    .frame(width: 220, height: 84).background(T.field, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(T.sep, lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder var service: some View {
        SGroup(title: "Google 翻译") {
            SRow(label: "API Key", hint: "Cloud Translation v2", first: true) { KField(text: $s.googleKey, secure: true) }
            SRow(label: "测试") {
                HStack(spacing: 8) {
                    if !googleMsg.isEmpty { Text(googleMsg).font(.system(size: 12)).foregroundStyle(T.fg2).lineLimit(2).frame(maxWidth: 190, alignment: .trailing) }
                    KBtn(title: "测试连接") { Task { googleMsg = "测试中…"; googleMsg = await Translator.shared.test(.google) } }
                }
            }
        }
        SGroup(title: "DeepL") {
            SRow(label: "API Key", hint: "免费版 Key 以 :fx 结尾", first: true) { KField(text: $s.deeplKey, secure: true) }
            SRow(label: "测试") {
                HStack(spacing: 8) {
                    if !deeplMsg.isEmpty { Text(deeplMsg).font(.system(size: 12)).foregroundStyle(T.fg2).lineLimit(2).frame(maxWidth: 190, alignment: .trailing) }
                    KBtn(title: "测试连接") { Task { deeplMsg = "测试中…"; deeplMsg = await Translator.shared.test(.deepl) } }
                }
            }
        }
        SGroup(title: "网络代理（Google、DeepL 使用）") {
            SRow(label: "使用代理", hint: "关闭时直连", first: true) { KSwitch(on: $s.proxyOn) }
            SRow(label: "类型") { KPopup(sel: $s.proxyType, items: [("SOCKS5", "SOCKS5"), ("HTTP", "HTTP")]) }
            SRow(label: "地址", hint: "host:port，例如 127.0.0.1:7890") { KField(text: $s.proxyHost) }
            SRow(label: "测试") {
                HStack(spacing: 8) {
                    if !proxyMsg.isEmpty { Text(proxyMsg).font(.system(size: 12)).foregroundStyle(T.fg2) }
                    KBtn(title: "测试代理") { Task { proxyMsg = "测试中…"; proxyMsg = await Translator.shared.testProxy() } }
                }
            }
        }
    }

    func loadModels() {
        let base = s.magpieURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/v1/models") else { return }
        let key = s.llmKey
        Task {
            let cfg = URLSessionConfiguration.ephemeral; cfg.connectionProxyDictionary = [:]; cfg.timeoutIntervalForRequest = 6
            var req = URLRequest(url: url)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            guard let (d, _) = try? await URLSession(configuration: cfg).data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let arr = j["data"] as? [[String: Any]] else { llmMsg = "获取模型列表失败"; return }
            let all = arr.compactMap { $0["id"] as? String }.sorted()
            let fast = all.filter { $0.contains("flash") || $0.contains("haiku") || $0.contains("mini") }
            models = fast.isEmpty ? all : fast
        }
    }

    @ViewBuilder var voice: some View {
        SGroup(title: "朗读") {
            SRow(label: "英文声音", hint: "使用系统语音；可在 系统设置 → 辅助功能 → 朗读内容 下载更高质量的声音", first: true) {
                KPopup(sel: $s.voiceEN, items: [("", "系统默认")] + Speech.voices("en").map { ($0.id, $0.name) })
            }
            SRow(label: "中文声音") {
                KPopup(sel: $s.voiceZH, items: [("", "系统默认")] + Speech.voices("zh").map { ($0.id, $0.name) })
            }
            SRow(label: "语速") {
                KPopup(sel: $s.speechRate, items: [(0.6, "0.6×"), (0.8, "0.8×"), (1.0, "1×（正常）"), (1.2, "1.2×"), (1.4, "1.4×")])
            }
            SRow(label: "试听") {
                HStack(spacing: 8) {
                    KBtn(title: "英文") { Speech.shared.speak("Serendipity is a lovely word.", lang: "en-US") }
                    KBtn(title: "中文") { Speech.shared.speak("机缘凑巧，是一个很美的词。", lang: "zh-CN") }
                }
            }
        }
    }

    @ViewBuilder var general: some View {
        SGroup(title: "通用") {
            SRow(label: "开机自启", first: true) { KSwitch(on: $s.launchAtLogin) }
            SRow(label: "关闭主窗口时退出 kiti", hint: "关闭时：窗口左上角红点关闭后整个 kiti 退出；默认不退出，继续留在菜单栏") { KSwitch(on: $s.quitOnClose) }
            SRow(label: "在 Dock 中显示", hint: "默认不显示，只留菜单栏图标") { KSwitch(on: $s.showInDock) }
            SRow(label: "界面大小", hint: "立即生效；也可在 kiti 窗口里按 ⌥＋ / ⌥－（或 ⌘＋ / ⌘－）缩放，⌥0 恢复 100%") { KPopup(sel: $s.uiScale, items: ScaleSync.labels) }
        }
        SGroup(title: "历史记录") {
            SRow(label: "导出 / 导入", hint: "词语、文章、文档的历史；导入时与本机合并，不会覆盖", first: true) {
                HStack(spacing: 8) {
                    KBtn(title: "导出…") { HistoryStore.shared.exportFile() }
                    KBtn(title: "导入…") { HistoryStore.shared.importFile() }
                }
            }
            SRow(label: "同步文件夹", hint: "选一个各台电脑都能访问的目录（如挂载的 NAS）。每台电脑只写自己的文件，并合并其他电脑的") {
                HStack(spacing: 8) {
                    Text(syncPath.isEmpty ? "未设置" : (syncPath as NSString).abbreviatingWithTildeInPath).font(.system(size: 12)).foregroundStyle(T.fg2).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .trailing)
                    KBtn(title: "选择…") { HistoryStore.shared.chooseSyncFolder(); syncPath = HistoryStore.shared.syncFolder; syncMsg = HistoryStore.shared.syncNow() }
                    if !syncPath.isEmpty { KBtn(title: "停用") { HistoryStore.shared.syncFolder = ""; syncPath = ""; syncMsg = "" } }
                }
            }
            if !syncPath.isEmpty {
                SRow(label: "立即同步", hint: syncMsg.isEmpty ? "启动时和之后每 10 分钟自动同步一次" : syncMsg) {
                    KBtn(title: "同步") { syncMsg = HistoryStore.shared.syncNow() }
                }
            }
        }
    }
}
