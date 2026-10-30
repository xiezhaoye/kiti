import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let picker = SelectionPicker()
    private let s = AppSettings.shared
    private let pop = PopoverController.shared
    private var trustTimer: Timer?
    private var syncTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        refreshIcon()

        s.onChange = { [weak self] in self?.refreshIcon(); if self?.s.autoPick == false { self?.pop.dismiss() } }
        s.onShortcuts = { [weak self] in self?.registerKeys() }
        registerKeys()

        picker.onText = { [weak self] text, p in
            guard let self = self, self.s.autoPick else { return }
            self.pop.show(text: text, at: p)
        }
        picker.onDismissGesture = { [weak self] in
            guard let self = self, self.pop.isVisible, !self.pop.contains(NSEvent.mouseLocation) else { return }
            self.pop.dismiss()
        }
        picker.start()
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.pop.dismiss() } }
        }

        if !SelectionReader.trusted { SelectionReader.requestTrust() }
        buildMainMenu()
        // ⌥+ / ⌥− (also ⌘+ / ⌘−) zoom the whole UI, ⌥0 resets
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard m == .option || m == .command || m == [.command, .shift] || m == [.option, .shift] else { return e }
            switch e.keyCode {
            case 24, 69: Task { @MainActor in ScaleSync.step(1) }; return nil
            case 27, 78: Task { @MainActor in ScaleSync.step(-1) }; return nil
            case 29 where m == .option, 82 where m == .option: Task { @MainActor in AppSettings.shared.uiScale = UIScale.standard }; return nil
            default: return e
            }
        }
        DockPresence.apply()
        MainWindow.show()

        // clicks / Esc while kiti itself is frontmost (the global monitors above ignore our own windows)
        // selecting text inside kiti's own main window (double-click a word, drag a phrase/sentence) behaves like the global picker
        var downAt = NSPoint.zero
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            if e.type == .leftMouseDown { downAt = NSEvent.mouseLocation; return e }
            guard let self = self, MainWindow.owns(e.window) else { return e }
            let p = NSEvent.mouseLocation
            guard e.clickCount >= 2 || hypot(p.x - downAt.x, p.y - downAt.y) > 6 else { return e }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let tv = e.window?.firstResponder as? NSTextView, tv.selectedRange().length > 0 else { return }
                let t = (tv.string as NSString).substring(with: tv.selectedRange()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.count <= 3000, t.rangeOfCharacter(from: .letters) != nil else { return }
                self.pop.show(text: t, at: p)
            }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self = self, self.pop.isVisible else { return e }
            if e.type == .keyDown { if e.keyCode == 53 { self.pop.dismiss(); return nil } }
            else if !self.pop.contains(NSEvent.mouseLocation) { self.pop.dismiss() }
            return e
        }

        // if Accessibility is granted while running, restart the picker straight away (no relaunch needed)
        var wasTrusted = SelectionReader.trusted
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            let now = SelectionReader.trusted
            if now != wasTrusted {
                wasTrusted = now
                if now { self?.picker.start(); HUD.show("辅助功能已授权，取词已启用") }
            }
        }

        // history sync folder: pull/push on launch and every 10 minutes
        if !HistoryStore.shared.syncFolder.isEmpty { HistoryStore.shared.syncNow() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            if !HistoryStore.shared.syncFolder.isEmpty { HistoryStore.shared.syncNow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    // MARK: system menu bar (visible while a kiti window is open)
    private func mi(_ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, target: AnyObject? = nil, chain: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        i.target = chain ? nil : (target ?? self)
        return i
    }

    private func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = m
        return top
    }

    func buildMainMenu() {
        let main = NSMenu()
        main.addItem(sub("lingo", [
            mi("关于 lingo", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            .separator(),
            mi("设置…", #selector(menuSettings), ","),
            .separator(),
            mi("隐藏 lingo", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            mi("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            mi("全部显示", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            mi("退出 lingo", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ]))
        main.addItem(sub("文件", [
            mi("文档翻译…", #selector(menuDoc), "o"),
            .separator(),
            mi("关闭窗口", #selector(NSWindow.performClose(_:)), "w", chain: true),
        ]))
        main.addItem(sub("编辑", [
            mi("撤销", Selector(("undo:")), "z", chain: true),
            mi("重做", Selector(("redo:")), "z", [.command, .shift], chain: true),
            .separator(),
            mi("剪切", #selector(NSText.cut(_:)), "x", chain: true),
            mi("拷贝", #selector(NSText.copy(_:)), "c", chain: true),
            mi("粘贴", #selector(NSText.paste(_:)), "v", chain: true),
            mi("全选", #selector(NSText.selectAll(_:)), "a", chain: true),
        ]))
        main.addItem(sub("查词与翻译", [
            mi("查词", #selector(menuMode(_:)), "1", tag: 0),
            mi("查句", #selector(menuMode(_:)), "2", tag: 1),
            mi("文档", #selector(menuMode(_:)), "3", tag: 2),
            .separator(),
            mi("查词…", #selector(menuFocusSearch), "l"),
            mi("翻译剪贴板内容", #selector(menuClip), "t", [.command, .shift]),
            mi("朗读选中文字", #selector(menuSpeak)),
            .separator(),
            mi("自动取词", #selector(menuToggle)),
        ]))
        main.addItem(sub("窗口", [
            mi("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", chain: true),
            mi("缩放", #selector(NSWindow.performZoom(_:)), chain: true),
            .separator(),
            mi("lingo 主窗口", #selector(menuMain), "0"),
        ]))
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }

    @objc func menuMode(_ s: NSMenuItem) { MainModel.shared.mode = [MainMode.dict, .trans, .doc][s.tag]; MainWindow.show() }
    @objc func menuFocusSearch() { MainWindow.show(); MainModel.shared.focusTick += 1 }
    @objc func menuSpeak() { speakSelection() }

    func registerKeys() {
        HotKeys.shared.register([
            (s.scToggle, { [weak self] in self?.toggleAuto() }),
            (s.scMain, { MainModel.shared.mode = .dict; MainWindow.show() }),
            (s.scClip, { [weak self] in self?.translateClipboard() }),
            (s.scSpeak, { [weak self] in self?.speakSelection() }),
            (s.scQuick, { QuickQuery.toggle() }),
        ])
    }

    func refreshIcon() {
        var img = Bundle.main.url(forResource: "menubar", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        if let i = img {
            i.size = NSSize(width: 20, height: 12)
            if let big = Bundle.main.url(forResource: "menubar@2x", withExtension: "png"), let rep = NSBitmapImageRep(data: (try? Data(contentsOf: big)) ?? Data()) {
                rep.size = NSSize(width: 20, height: 12); i.addRepresentation(rep)
            }
        } else {
            img = NSImage(systemSymbolName: s.autoPick ? "character.book.closed.fill" : "character.book.closed", accessibilityDescription: "lingo")
        }
        img?.isTemplate = true
        item.button?.image = img
        item.button?.appearsDisabled = !s.autoPick
    }

    func toggleAuto() {
        s.autoPick.toggle()
        HUD.show(s.autoPick ? "自动取词已开启" : "自动取词已关闭")
    }

    func translateClipboard() {
        guard let t = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            HUD.show("剪贴板里没有文字"); return
        }
        pop.showTranslation(text: t, at: NSEvent.mouseLocation)
    }

    func speakSelection() {
        SelectionReader.read { text in
            let t = text ?? NSPasteboard.general.string(forType: .string) ?? ""
            if t.isEmpty { HUD.show("没有可朗读的文字") } else { Speech.shared.speakAuto(t) }
        }
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "lingo", action: nil, keyEquivalent: ""); head.isEnabled = false
        menu.addItem(head)
        if !SelectionReader.trusted {
            let w = NSMenuItem(title: "⚠︎ 未授权辅助功能，取词不可用 — 点此打开设置", action: #selector(menuTrust), keyEquivalent: "")
            w.target = self; menu.addItem(w)
        }
        menu.addItem(.separator())
        add(menu, "自动取词", #selector(menuToggle), s.scToggle).state = s.autoPick ? .on : .off
        add(menu, "打开主窗口", #selector(menuMain), s.scMain)
        add(menu, "快速查询", #selector(menuQuick), s.scQuick)
        add(menu, "翻译剪贴板内容", #selector(menuClip), s.scClip)
        add(menu, "文档翻译…", #selector(menuDoc), nil)
        add(menu, "取词诊断…", #selector(menuDiag), nil)
        menu.addItem(.separator())
        let set = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        set.target = self; menu.addItem(set)
        let q = NSMenuItem(title: "退出 lingo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
    }

    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ sc: Shortcut?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        if let sc = sc, sc.label.count == 1, sc.label != "␣" {
            i.keyEquivalent = sc.label.lowercased()
            var f: NSEvent.ModifierFlags = []
            if sc.mods & UInt32(0x0100) != 0 { f.insert(.command) }
            if sc.mods & UInt32(0x0800) != 0 { f.insert(.option) }
            if sc.mods & UInt32(0x0200) != 0 { f.insert(.shift) }
            if sc.mods & UInt32(0x1000) != 0 { f.insert(.control) }
            i.keyEquivalentModifierMask = f
        } else if let sc = sc {
            i.title = "\(title)    \(sc.display)"
        }
        m.addItem(i)
        return i
    }

    @objc func menuTrust() {
        SelectionReader.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func menuDiag() {
        let trusted = SelectionReader.trusted
        var lines = [
            "辅助功能授权：\(trusted ? "已授权" : "未授权 ← 这是取词无效的最常见原因")",
            "自动取词开关：\(s.autoPick ? "开" : "关")",
            "鼠标监听：\(SelectionPicker.started != nil ? "已启动" : "未启动")",
            "选句子自动翻译：\(s.autoSentence ? "开" : "关（会先出「翻译」胶囊）")",
            "",
            "最近的划选手势："
        ]
        lines += SelectionPicker.diag.isEmpty ? ["（还没有收到。请在别的 App 里选一段文字，再回来点诊断）"] : SelectionPicker.diag.reversed()
        let a = NSAlert()
        a.messageText = "取词诊断"
        a.informativeText = lines.joined(separator: "\n")
        a.addButton(withTitle: "好")
        if !trusted { a.addButton(withTitle: "打开辅助功能设置") }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { menuTrust() }
    }
    @objc func menuToggle() { toggleAuto() }
    @objc func menuMain() { MainModel.shared.mode = .dict; MainWindow.show() }
    @objc func menuQuick() { QuickQuery.show() }
    @objc func menuClip() { translateClipboard() }
    @objc func menuDoc() { MainModel.shared.openDoc() }
    @objc func menuSettings() { SettingsWindow.show() }
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--dump" {
    for w in CommandLine.arguments.dropFirst(2) {
        guard let e = LocalDictionary.lookup(w) else { print("\(w): nil"); continue }
        print("== \(e.headword)  \(e.phonetic)  \(Ecdict.info(for: e.headword).map { "\($0.chips(maxTags: 4).map(\.text)) rel=\($0.related)" } ?? "no-info")")
        for b in e.blocks { for s in b.senses { print("  [\(b.pos)] \(s.gloss) | \(s.zh)\(s.ex.map { "  >> " + $0 } ?? "")") } }
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--wintest" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        MainWindow.placeButtons(w)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        for k in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let b = w.standardWindowButton(k)!
            let r = b.convert(b.bounds, to: nil)
            print(k.rawValue, "hidden:", b.isHidden, "inWindow:", r, "winH:", w.frame.height)
        }
    }
    exit(0)
}

if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--snap" {
    let kind = CommandLine.arguments[2], out = CommandLine.arguments[3]
    let dark = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "dark"
    // Snapshot-only override in the volatile argument domain; never persist UI preferences.
    if let index = CommandLine.arguments.firstIndex(of: "--scale"), index + 1 < CommandLine.arguments.count,
       let scale = Double(CommandLine.arguments[index + 1]), UIScale.steps.contains(scale) {
        UserDefaults.standard.setVolatileDomain(["uiScale": scale], forName: UserDefaults.argumentDomain)
    }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view: NSView
        let k = CGFloat(AppSettings.shared.uiScale)
        var size = NSSize(width: 780 * k, height: 520 * k)
        switch kind {
        case "dock-icon":
            guard let image = Bundle.main.image(forResource: "dock-icon") ?? NSImage(contentsOfFile: "Resources/dock-icon.png") else { fatalError("Missing Dock artwork") }
            view = TransparentDockIcon(image: image)
            size = NSSize(width: 256, height: 256)
        case "popover", "poptrans", "poperror", "capsule":
            let m = PopoverController.shared.model
            m.kind = .word; m.text = "rationale"; m.entry = LocalDictionary.lookup("rationale")
            if kind == "capsule" { m.kind = .capsule }
            if kind == "poptrans" || kind == "poperror" {
                m.kind = .translate; m.text = "The committee wants a clear rationale before approving the plan."
                m.output = "委员会希望在批准该计划之前，先有一个明确的理由。"
                m.state = kind == "poperror" ? .failed("无法连接到翻译服务", "连接超时。请检查接口地址和网络后重试。") : .done
                m.canFallback = kind == "poperror"
            }
            let h = NSHostingView(rootView: ScaleFit { PopoverView(model: m, ctl: PopoverController.shared) })
            size = h.fittingSize; if size.width < 1 || size.height < 1 { size = NSSize(width: 380 * k, height: 300 * k) }; view = h
        case "llm", "api", "keys", "voice", "general":
            SettingsView.startTab = ["keys": 0, "llm": 1, "api": 2, "voice": 3, "general": 4][kind] ?? 0; let v = SettingsView()
            size = NSSize(width: SettingsWindow.designSize.width * k, height: SettingsWindow.designSize.height * k)
            view = NSHostingView(rootView: ScaleFill { v })
        case "doc", "doc-empty", "doc-error":
            let m = MainModel.shared
            m.mode = .doc
            if kind != "doc-empty" {
                m.docName = "Designing for clarity.md"
                m.docText = "Good design begins with a clear understanding of the task."
                m.segs = [
                    DocSeg(id: 0, src: m.docText, out: "好的设计，始于对任务的清晰理解。", status: .done),
                    DocSeg(id: 1, src: "The interface should make the content easier to read.", out: "界面应当让内容更容易阅读。", status: .done),
                    DocSeg(id: 2, src: "Every action needs a visible and consistent response.", out: kind == "doc-error" ? "〔失败〕连接超时，请重新翻译。" : "每一次操作，都需要可见且一致的反馈。", status: kind == "doc-error" ? .failed : .run),
                    DocSeg(id: 3, src: "Keep the original behavior while improving the presentation."),
                    DocSeg(id: 4, src: "Small details help people find their way.")
                ]
                m.docRunning = true
            }
            view = NSHostingView(rootView: ScaleFill { MainView() })
        case "zh":
            MainModel.shared.lookup("章鱼")
            view = NSHostingView(rootView: ScaleFill { MainView() })
        case "word":
            MainModel.shared.lookup("run")
            view = NSHostingView(rootView: ScaleFill { MainView() })
        case "trans", "trans-error":
            MainModel.shared.mode = .trans; MainModel.shared.src = "The committee wants a clear rationale before approving the plan."
            MainModel.shared.out = "委员会希望在批准该计划之前先有一个明确的理由。"
            MainModel.shared.input = MainModel.shared.src
            if kind == "trans-error" { MainModel.shared.tState = .failed("无法连接到翻译服务", "连接超时。请检查接口地址和网络后重试。") }
            view = NSHostingView(rootView: ScaleFill { MainView() })
        default:
            let model = MainModel.shared
            model.mode = .dict
            if CommandLine.arguments.contains("--public-snapshot") {
                // Public screenshots must never contain or write the user's real history.
                let sampleDate = Date(timeIntervalSince1970: 1_767_225_600)
                model.history = ["rationale", "curious", "clarity", "design"].map { HItem(w: $0, t: sampleDate) }
            }
            model.lookup("rationale", record: !CommandLine.arguments.contains("--public-snapshot"))
            view = NSHostingView(rootView: ScaleFill { MainView() })
        }
        if CommandLine.arguments.contains("--small"), !["popover", "poptrans", "poperror", "capsule", "llm", "api", "keys", "voice", "general"].contains(kind) {
            size = NSSize(width: 640 * k, height: 420 * k)
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSApp.appearance
        if kind == "dock-icon" { w.isOpaque = false; w.backgroundColor = .clear }
        w.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
