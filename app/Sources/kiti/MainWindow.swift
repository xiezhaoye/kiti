import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MainMode: String { case dict, trans, doc }

protocol Dated { var t: Date { get } }
extension Dated {
    var time: String { let f = DateFormatter(); f.dateFormat = "H:mm"; return f.string(from: t) }
    var dayKey: String { let c = Calendar.current.dateComponents([.year, .month, .day], from: t); return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)" }
    var dayTitle: String {
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = cal.component(.year, from: t) == cal.component(.year, from: Date()) ? "M月d日" : "yyyy年M月d日"
        let d = f.string(from: t)
        if cal.isDateInToday(t) { return "今天 · " + d }
        if cal.isDateInYesterday(t) { return "昨天 · " + d }
        return d
    }
}

struct HItem: Codable, Hashable, Dated {
    var w: String
    var t: Date
}
extension ArticleItem: Dated {}
extension DocItem: Dated {}

struct DocSeg: Identifiable {
    let id: Int
    let src: String
    var out = ""
    var status: Status = .queue
    enum Status { case queue, run, done, failed }
}

/// One row of the left history list.
struct HRow: Identifiable {
    let id: String
    let day: String
    let dayTitle: String
    let title: String
    let time: String
    let selected: Bool
    let open: () -> Void
}

@MainActor
final class MainModel: ObservableObject {
    static let shared = MainModel()
    let settings = AppSettings.shared
    private let store = HistoryStore.shared

    @Published var mode: MainMode = .dict
    @Published var focusTick = 0
    /// the universal input box
    @Published var input = ""
    // dictionary
    @Published var query = ""
    @Published var entry: DictEntry?
    @Published var notFound = false
    @Published var history: [HItem]
    @Published var articles: [ArticleItem]
    @Published var docs: [DocItem]
    // translate
    @Published var src = "" { didSet { if src != oldValue { dirLocked = false } } }
    var dirLocked = false
    @Published var out = ""
    @Published var tState: TState = .idle
    @Published var dst = "zh"
    private var articleID: String?
    // document
    @Published var docText = ""
    @Published var docName = ""
    @Published var segs: [DocSeg] = []
    @Published var docRunning = false
    private var docID: String?
    private var tTask: Task<Void, Never>?
    private var docTask: Task<Void, Never>?

    init() {
        history = store.data.words; articles = store.data.articles; docs = store.data.docs
        store.onExternalChange = { [weak self] in self?.reloadHistory() }
    }

    private func reloadHistory() { history = store.data.words; articles = store.data.articles; docs = store.data.docs }
    private func persist() { store.save(HistoryData(words: history, articles: articles, docs: docs)) }

    func addHistory(_ w: String) {
        // a plain log: a word keeps its first position/date, re-lookups do not reorder it
        guard !history.contains(where: { $0.w.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        history.insert(HItem(w: w, t: Date()), at: 0)
        history = Array(history.prefix(HistoryStore.capWords))
        persist()
    }

    private func saveArticle() {
        let id = articleID ?? UUID().uuidString
        articleID = id
        let it = ArticleItem(id: id, src: src, out: out, dst: dst, t: Date())
        if let i = articles.firstIndex(where: { $0.id == id }) { articles.remove(at: i) }
        articles.insert(it, at: 0)
        articles = Array(articles.prefix(HistoryStore.capArticles))
        persist()
    }

    private func saveDoc() {
        guard let id = docID, segs.contains(where: { !$0.out.isEmpty }) else { return }
        let it = DocItem(id: id, name: docName, text: docText, outs: segs.map { $0.out }, dst: dst, t: Date())
        if let i = docs.firstIndex(where: { $0.id == id }) { docs.remove(at: i) }
        docs.insert(it, at: 0)
        docs = Array(docs.prefix(HistoryStore.capDocs))
        persist()
    }

    /// Rows for the left list of the current tab.
    func rows(_ m: MainMode) -> [HRow] {
        switch m {
        case .dict:
            return history.map { h in HRow(id: "w" + h.w, day: h.dayKey, dayTitle: h.dayTitle, title: h.w, time: h.time,
                                           selected: entry?.headword == h.w) { [weak self] in self?.lookup(h.w, quiet: true) } }
        case .trans:
            return articles.map { a in HRow(id: a.id, day: a.dayKey, dayTitle: a.dayTitle,
                                            title: a.src.replacingOccurrences(of: "\n", with: " "), time: a.time,
                                            selected: articleID == a.id) { [weak self] in self?.restoreArticle(a) } }
        case .doc:
            return docs.map { d in HRow(id: d.id, day: d.dayKey, dayTitle: d.dayTitle, title: d.name, time: d.time,
                                        selected: docID == d.id) { [weak self] in self?.restoreDoc(d) } }
        }
    }

    func clearHistory(_ m: MainMode) {
        switch m { case .dict: history = []; case .trans: articles = []; case .doc: docs = [] }
        persist()
    }

    // dictionary navigation (back / forward over what was looked up)
    @Published var backStack: [String] = []
    @Published var fwdStack: [String] = []
    private var current = ""
    // Chinese query → English candidates
    @Published var zhQuery = ""
    @Published var cands: [String] = []
    @Published var candState: TState = .idle
    private var candTask: Task<Void, Never>?

    func goBack() { guard let p = backStack.popLast() else { return }; fwdStack.append(current); lookup(p, record: false, quiet: true) }
    func goForward() { guard let n = fwdStack.popLast() else { return }; backStack.append(current); lookup(n, record: false, quiet: true) }

    /// A word or short phrase (looked up) as opposed to a sentence/paragraph (translated).
    static func isWordLike(_ w: String) -> Bool {
        if w.contains("\n") { return false }
        if w.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？，；：.!?,;:、")) != nil, !w.hasSuffix("."), w.count > 2 { return false }
        return LocalDictionary.isCJK(w) ? w.count <= 8 : w.split(separator: " ").count <= 3
    }

    /// The universal input: a file goes to documents, a short word is looked up, anything longer is translated.
    func submit() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t.hasPrefix("/"), !t.contains("\n"), FileManager.default.fileExists(atPath: t) { handleFile(URL(fileURLWithPath: t)); return }
        lookup(t)
    }

    func handleFile(_ url: URL) {
        mode = .doc
        guard loadDoc(url: url) else { return }
        input = ""
        startDoc()
    }

    /// `quiet`: never leave the dictionary page (used for clicks and back/forward).
    func lookup(_ q: String, record: Bool = true, quiet: Bool = false) {
        let w = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        // a sentence or paragraph belongs to the article tab
        if !quiet, !Self.isWordLike(w) { openTranslate(w, run: true); return }
        mode = .dict
        input = w
        if record, w != current { if !current.isEmpty { backStack.append(current) }; fwdStack = [] }
        current = w
        query = w
        candTask?.cancel()
        if LocalDictionary.isChinese(w) {
            entry = nil; notFound = false; zhQuery = w
            loadCandidates(w)
            return
        }
        zhQuery = ""; cands = []
        entry = LocalDictionary.lookup(w)
        notFound = entry == nil
        if let e = entry { addHistory(e.headword) }
    }

    private func loadCandidates(_ zh: String) {
        cands = []; candState = .loading
        // 1) system dictionary (汉英): take the English headwords out of its senses
        if let e = LocalDictionary.lookup(zh) {
            var seen = Set<String>(), out: [String] = []
            let strip = try! NSRegularExpression(pattern: "[\\(（\\[‹«][^\\)）\\]›»]*[\\)）\\]›»]")
            for b in e.blocks { for sense in b.senses {
                let t = strip.stringByReplacingMatches(in: sense.zh, range: NSRange(sense.zh.startIndex..., in: sense.zh), withTemplate: "")
                for piece in t.components(separatedBy: CharacterSet(charactersIn: ";,，；")) {
                    let c = piece.trimmingCharacters(in: .whitespaces)
                    if c.range(of: #"^[A-Za-z][A-Za-z'’\- ]{0,28}$"#, options: .regularExpression) != nil, c.split(separator: " ").count <= 3,
                       seen.insert(c.lowercased()).inserted { out.append(c) }
                }
            } }
            if !out.isEmpty { cands = Array(out.prefix(8)); candState = .done; return }
        }
        // 2) not in the dictionary: ask the translation service for a few common English words
        let prov = settings.provider
        candTask = Task { [weak self] in
            do {
                let r = try await Translator.shared.suggestEnglish(zh, provider: prov)
                guard let self = self, !Task.isCancelled, self.zhQuery == zh else { return }
                self.cands = r; self.candState = r.isEmpty ? .failed("没有得到英文结果", "可以换个说法再试。") : .done
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                let te = (error as? TranslateError) ?? .network(error.localizedDescription)
                self?.candState = .failed(te.title, te.detail)
            }
        }
    }

    func openWord(_ w: String) { lookup(w, quiet: true); MainWindow.show() }

    func openTranslate(_ text: String, run: Bool) {
        mode = .trans; src = text; input = ""; out = ""; tState = .idle; articleID = nil
        MainWindow.show()
        if run { translate() }
    }

    /// Popover translation → main window: reuse the finished result instead of translating again.
    func openTranslated(_ text: String, out: String?, dst d: String) {
        if let out = out, !out.isEmpty {
            recordArticle(text, out: out, dst: d)
            if let a = articles.first(where: { $0.src == text }) { restoreArticle(a) }
            MainWindow.show()
        } else { openTranslate(text, run: true) }
    }

    /// Adds a finished popover translation to the 查句 history (same source text → replaced, not duplicated).
    func recordArticle(_ text: String, out: String, dst d: String) {
        let id = articles.first(where: { $0.src == text })?.id ?? UUID().uuidString
        articles.removeAll { $0.id == id }
        articles.insert(ArticleItem(id: id, src: text, out: out, dst: d, t: Date()), at: 0)
        articles = Array(articles.prefix(HistoryStore.capArticles))
        persist()
    }

    func openDoc() { mode = .doc; MainWindow.show() }

    private func restoreArticle(_ a: ArticleItem) {
        tTask?.cancel()
        mode = .trans; src = a.src; input = ""; out = a.out; dst = a.dst; dirLocked = true; tState = .done; articleID = a.id
    }

    private func restoreDoc(_ d: DocItem) {
        docTask?.cancel(); docRunning = false
        mode = .doc; docText = d.text; docName = d.name; docID = d.id; dst = d.dst; dirLocked = true
        segs = MainModel.split(d.text).enumerated().map { i, s in
            let o = i < d.outs.count ? d.outs[i] : ""
            return DocSeg(id: i, src: s, out: o, status: o.isEmpty ? .queue : (o.hasPrefix("〔失败〕") ? .failed : .done))
        }
    }

    // MARK: translate
    func translate(skipCache: Bool = false) {
        let text = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        tTask?.cancel()
        if !dirLocked { dst = Translator.detectDirection(text, settings.direction).dst }
        runTranslate(text, skipCache: skipCache)
    }

    func swapDirection() {
        dst = dst == "zh" ? settings.otherLang : "zh"
        dirLocked = true
        let text = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { runTranslate(text, skipCache: false) }
    }

    private func runTranslate(_ text: String, skipCache: Bool) {
        tTask?.cancel()
        out = ""; tState = .loading
        let prov = settings.provider, d = dst
        tTask = Task { [weak self] in
            do {
                try await Translator.shared.translate(text, dst: d, provider: prov, skipCache: skipCache) { s in
                    Task { @MainActor in
                        guard let self = self, !Task.isCancelled else { return }
                        self.out = s; self.tState = .streaming
                    }
                }
                if !Task.isCancelled { self?.tState = .done; self?.saveArticle() }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                let te = (error as? TranslateError) ?? .network(error.localizedDescription)
                self?.tState = .failed(te.title, te.detail)
            }
        }
    }

    // MARK: document
    @discardableResult
    func loadDoc(url: URL) -> Bool {
        guard let s = DocReader.read(url), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { HUD.show("无法读取这个文件（扫描版 PDF 暂不支持）"); return false }
        docText = s; docName = url.lastPathComponent; segs = []; docID = UUID().uuidString; dirLocked = false
        return true
    }

    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        for p in text.components(separatedBy: "\n\n") {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.count <= 1200 { parts.append(t); continue }
            var cur = ""
            for sent in t.replacingOccurrences(of: ". ", with: ".\u{1}").split(separator: "\u{1}") {
                if cur.count + sent.count > 1000, !cur.isEmpty { parts.append(cur); cur = "" }
                cur += (cur.isEmpty ? "" : " ") + sent
            }
            if !cur.isEmpty { parts.append(cur) }
        }
        return parts
    }

    var docProgress: Double {
        guard !segs.isEmpty else { return 0 }
        return Double(segs.filter { $0.status == .done }.count) / Double(segs.count)
    }

    func startDoc() {
        let parts = MainModel.split(docText)
        guard !parts.isEmpty else { HUD.show("没有可翻译的文字"); return }
        docTask?.cancel()
        segs = parts.enumerated().map { DocSeg(id: $0.offset, src: $0.element) }
        docRunning = true
        let prov = settings.provider
        let dir = dirLocked ? dst : Translator.detectDirection(docText, settings.direction).dst
        dst = dir
        docTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                let total = parts.count
                func add() {
                    guard next < total, !Task.isCancelled else { return }
                    let i = next; next += 1
                    group.addTask { await self?.doSeg(i, parts[i], dst: dir, provider: prov) }
                }
                for _ in 0..<min(3, total) { add() }
                while await group.next() != nil { add() }
            }
            await MainActor.run { self?.docRunning = false; self?.saveDoc() }
        }
    }

    private func doSeg(_ i: Int, _ text: String, dst: String, provider: Provider) async {
        await MainActor.run { if i < segs.count { segs[i].status = .run } }
        do {
            try await Translator.shared.translate(text, dst: dst, provider: provider) { s in
                Task { @MainActor in if i < self.segs.count, !Task.isCancelled { self.segs[i].out = s } }
            }
            await MainActor.run { if i < segs.count, !Task.isCancelled { segs[i].status = .done } }
        } catch {
            if Task.isCancelled { return }
            let te = (error as? TranslateError)?.detail ?? error.localizedDescription
            await MainActor.run { if i < segs.count { segs[i].status = .failed; segs[i].out = "〔失败〕\(te)" } }
        }
    }

    func cancelDoc() {
        docTask?.cancel(); docRunning = false; saveDoc()
        for i in segs.indices where segs[i].status == .run || segs[i].status == .queue { segs[i].status = .queue }
    }

    var docOutput: String { segs.map { $0.out }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

// MARK: - window

@MainActor
enum MainWindow {
    private static var window: NSWindow?
    /// Taller title band: the traffic lights sit on its centre line (level with the Kiti title).
    static let band: CGFloat = 56
    static func placeButtons(_ w: NSWindow) {
        guard let close = w.standardWindowButton(.closeButton), let bar = close.superview, let container = bar.superview,
              let frameView = container.superview else { return }
        container.frame = NSRect(x: 0, y: frameView.bounds.height - band, width: frameView.bounds.width, height: band)
        bar.frame = container.bounds
        for (i, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(kind) else { continue }
            b.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 20, y: (band - b.frame.height) / 2))
        }
    }
    static func owns(_ w: NSWindow?) -> Bool { w != nil && w === window }

    static func show() {
        if window == nil {
            let k = CGFloat(AppSettings.shared.uiScale)
            let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            let size = NSSize(width: min(780 * k, vis.width * 0.92), height: min(520 * k, vis.height * 0.92))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "kiti"
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgba(0x26272b) : rgba(0xf8f8fa) }
            w.titleVisibility = .hidden
            // taller title band so the traffic lights sit on its centre line, level with the Kiti title
            let place: (Notification?) -> Void = { [weak w] _ in if let w = w { MainWindow.placeButtons(w) } }
            for n in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(forName: n, object: w, queue: .main, using: place)
            }
            DispatchQueue.main.async { place(nil) }
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 640 * k, height: 420 * k)
            w.contentView = NSHostingView(rootView: ScaleFill { MainView() })
            w.center()
            w.setFrameAutosaveName("kitiMain2")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                if AppSettings.shared.quitOnClose { NSApp.terminate(nil) }
            }
            ScaleSync.bind(w, base: NSSize(width: 780, height: 520), minBase: NSSize(width: 640, height: 420), fixed: false)
            window = w
        }
        DockPresence.windowOpened()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - views

/// kiti lives in the menu bar; while one of its windows is open it also gets a Dock icon and a full menu bar.
@MainActor
enum DockPresence {
    /// Dock icon only when the user asked for it (设置 → 通用); otherwise kiti stays a pure menu-bar app.
    static func apply() {
        let want: NSApplication.ActivationPolicy = AppSettings.shared.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }
    static func windowOpened() { apply() }
}

struct Sep: View { var body: some View { Rectangle().fill(T.sep).frame(height: 0.5) } }
struct VSep: View { var body: some View { Rectangle().fill(T.sep).frame(width: 0.5) } }

struct MainView: View {
    @ObservedObject var m = MainModel.shared
    @ObservedObject var s = AppSettings.shared
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            SideColumn()
            VSep()
            VStack(spacing: 0) {
                InputBar()
                Sep()
                Group {
                    switch m.mode {
                    case .dict: DictPane()
                    case .trans: TransPane()
                    case .doc: DocPane()
                    }
                }
                Sep()
                HStack(spacing: 8) {
                    Circle().fill(T.ok).frame(width: 5, height: 5)
                    Text(m.mode == .dict ? "系统词典 · 牛津英汉汉英" : (s.provider == .magpie ? s.modelShort : s.provider.title))
                        .font(.system(size: 10.5)).foregroundStyle(T.fg2)
                    Spacer()
                    if m.mode == .doc { Text("译文会缓存，重翻同一段不再消耗额度").font(.system(size: 10)).foregroundStyle(T.fg2) }
                }
                .padding(.horizontal, 16).frame(height: T.footerHeight)
            }
        }
        .background(T.win)
        .foregroundStyle(T.fg)
        .frame(minWidth: 640, minHeight: 420)
        .ignoresSafeArea()
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(6).allowsHitTesting(false) } }
        .onChange(of: m.focusTick) { _ in m.mode = .dict }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { DispatchQueue.main.async { m.handleFile(url: u) } }
            }
            return true
        }
    }
}

extension MainModel { func handleFile(url: URL) { handleFile(url) } }

/// Left column: the three categories, the per-day history of the current one, and settings.
struct SideColumn: View {
    @ObservedObject var m = MainModel.shared
    @ObservedObject private var st = AppSettings.shared
    private var k: CGFloat { CGFloat(st.uiScale) }
    @State private var collapsed: Set<String> = []     // days the user folded; today is open by default

    private var days: [(key: String, title: String, rows: [HRow])] {
        var out: [(key: String, title: String, rows: [HRow])] = []
        for r in m.rows(m.mode) {
            if let i = out.firstIndex(where: { $0.key == r.day }) { out[i].rows.append(r) }
            else { out.append((r.day, r.dayTitle, [r])) }
        }
        return out
    }
    private var todayKey: String { HItem(w: "", t: Date()).dayKey }
    private func isOpen(_ k: String) -> Bool { collapsed.contains(m.mode.rawValue + k) ? false : true }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Kiti").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(T.fg); Spacer() }
                .padding(.leading, 92 / k).padding(.trailing, 16).frame(height: 56 / k)
            KSeg(height: 30, items: [(MainMode.dict, "查词"), (.trans, "查句"), (.doc, "文档")], sel: $m.mode)
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(days, id: \.key) { day in
                        let open = isOpen(day.key)
                        let tag = m.mode.rawValue + day.key
                        Button { if open { collapsed.insert(tag) } else { collapsed.remove(tag) } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 8)
                                Text(day.title).font(.system(size: 11, weight: .semibold))
                                Spacer(minLength: 4)
                                Text("\(day.rows.count)").font(.system(size: 11)).monospacedDigit()
                            }
                            .foregroundStyle(T.fg3).padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if open {
                            ForEach(day.rows) { r in
                                Button(action: r.open) {
                                    HStack(spacing: 8) {
                                        Text(r.title).font(.system(size: 13, weight: r.selected ? .medium : .regular)).foregroundStyle(r.selected ? T.accent : T.fg).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(r.time).font(.system(size: 10)).foregroundStyle(r.selected ? T.accent : T.fg3).monospacedDigit()
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(r.selected ? T.fill2 : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if days.isEmpty {
                        Text(m.mode == .dict ? "还没有查过的词" : m.mode == .trans ? "还没有翻译过的文章" : "还没有翻译过的文档")
                            .font(.system(size: 12)).foregroundStyle(T.fg3).padding(9)
                    }
                }
                .padding(.horizontal, 9).padding(.bottom, 8)
            }
            Sep()
            HStack {
                Text(m.mode == .dict ? "最近 \(m.history.count) 词" : m.mode == .trans ? "最近 \(m.articles.count)/\(HistoryStore.capArticles) 篇" : "最近 \(m.docs.count)/\(HistoryStore.capDocs) 份")
                    .font(.system(size: 11)).foregroundStyle(T.fg3)
                Spacer()
                IconButton(symbol: "gearshape", tip: "设置") { SettingsWindow.show() }
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: T.footerHeight)
        }
        .frame(width: 200).background(T.side)
    }
}

/// Right top: back / forward and the one input that routes by what is typed.
struct InputBar: View {
    @ObservedObject var m = MainModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            HStack(spacing: 0) {
                IconButton(symbol: "chevron.left", tip: "后退") { m.goBack() }.opacity(m.backStack.isEmpty ? 0.35 : 1).disabled(m.backStack.isEmpty)
                IconButton(symbol: "chevron.right", tip: "前进") { m.goForward() }.opacity(m.fwdStack.isEmpty ? 0.35 : 1).disabled(m.fwdStack.isEmpty)
            }.padding(.top, 2)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(T.fg3).padding(.top, 2)
                OmniInput(text: $m.input, placeholder: "输入单词或句子，回车；也可以把文件拖进来", focusToken: m.focusTick,
                          onSubmit: { m.submit() }, onFile: { m.handleFile($0) })
                if !m.input.isEmpty {
                    Button { m.input = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(T.fg3) }
                        .buttonStyle(.plain).padding(.top, 1)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(T.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.sep, lineWidth: 0.7))
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.top, 16).padding(.bottom, 15)
        .frame(minHeight: 52, alignment: .top)
    }
}

struct DictPane: View {
    @ObservedObject var m = MainModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !m.zhQuery.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(m.zhQuery).font(.system(size: 30, weight: .semibold)).foregroundStyle(T.fg)
                        Rectangle().fill(T.sep).frame(height: 0.5)
                        Text("英文").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.fg3)
                        switch m.candState {
                        case .failed(let t, let d):
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.warn)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t).font(.system(size: 13, weight: .semibold))
                                    Text(d).font(.system(size: 12.5)).foregroundStyle(T.fg2)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(T.warnSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        case .loading, .idle:
                            Text("正在查找…").font(.system(size: 13)).foregroundStyle(T.fg2)
                        default:
                            FlowRow(spacing: 8) {
                                ForEach(m.cands, id: \.self) { c in
                                    Button { m.lookup(c, quiet: true) } label: {
                                        Text(c).font(.system(size: 17, weight: .medium)).foregroundStyle(T.accent)
                                            .padding(.horizontal, 14).frame(height: T.footerHeight)
                                            .background(T.fill, in: Capsule())
                                    }.buttonStyle(PressStyle())
                                }
                            }
                            Text("点一个英文词，查看它的词条").font(.system(size: 12)).foregroundStyle(T.fg3)
                        }
                    }
                } else if let e = m.entry {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(e.headword).font(.system(size: 28, weight: .semibold)).foregroundStyle(T.fg)
                            IconButton(symbol: "doc.on.doc", tip: "复制单词、音标和全部释义") { copyToPasteboard(e.fullText) }
                        }
                        PronunciationRow(entry: e)
                    }
                    let info = Ecdict.info(for: e.headword)
                    if let info = info, !info.chips(maxTags: 4).isEmpty { ChipRow(chips: info.chips(maxTags: 4)) }
                    VStack(alignment: .leading, spacing: 7) {
                        Rectangle().fill(T.sep).frame(height: 0.5)
                        Text("释义").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.fg3).padding(.top, 5)
                        SenseList(blocks: e.blocks, limit: 14, onWord: { PopoverController.shared.peek($0) })
                        if e.senseCount > 14 {
                            Text("还有 \(e.senseCount - 14) 条义项，可在系统“词典”App 中查看。").font(.system(size: 12)).foregroundStyle(T.fg3).padding(.top, 4)
                        }
                    }
                    if let rel = info?.related, !rel.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Rectangle().fill(T.sep).frame(height: 0.5)
                            Text("相关").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.fg3).padding(.top, 5)
                            FlowRow(spacing: 6) {
                                ForEach(rel, id: \.self) { w in
                                    Button { m.lookup(w, quiet: true) } label: {
                                        Text(w).font(.system(size: 13)).foregroundStyle(T.accent).padding(.horizontal, 10).padding(.vertical, 1)
                                            .background(T.fill, in: Capsule())
                                    }.buttonStyle(PressStyle())
                                }
                            }
                        }
                    }
                } else if m.notFound {
                    VStack(spacing: 4) {
                        Text("系统词典里没有“\(m.query)”").font(.system(size: 17, weight: .semibold))
                        Text("可以把它交给翻译服务。").foregroundStyle(T.fg2)
                        KBtn(title: "翻译这个词", primary: true) { m.openTranslate(m.query, run: true) }.padding(.top, 10)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    VStack(spacing: 4) {
                        Text("查一个词").font(.system(size: 17, weight: .semibold))
                        Text("在上面输入单词或中文，回车查询。").foregroundStyle(T.fg2)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 24)
        }
    }
}

struct PaneLabel: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.fg3)
            Spacer()
            trailing
        }.frame(minHeight: 24)
    }
}

struct TransPane: View {
    @ObservedObject var m = MainModel.shared
    var body: some View {
        if m.src.isEmpty && m.out.isEmpty {
            VStack(spacing: 4) {
                Text("翻译文章").font(.system(size: 17, weight: .semibold))
                Text("在上面输入一句话或一段文字，回车翻译。").foregroundStyle(T.fg2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text("原文").font(.system(size: 12, weight: .medium)).foregroundStyle(T.fg2)
                        Text("\(m.src.count) 字").font(.system(size: 11)).foregroundStyle(T.fg3).monospacedDigit()
                        Spacer()
                        IconButton(symbol: "speaker.wave.2", tip: "朗读原文") { Speech.shared.speakAuto(m.src) }
                        IconButton(symbol: "doc.on.doc", tip: "复制原文") { copyToPasteboard(m.src) }
                    }
                    WordText(runs: [WordRun(text: m.src, size: 14, color: T.fg2)], lineSpacing: 7, onWord: { PopoverController.shared.peek($0) })
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Sep()
                    HStack(spacing: 8) {
                        Text("译文").font(.system(size: 12, weight: .medium)).foregroundStyle(T.fg2)
                        Spacer()
                        DirPill(from: m.dst == "zh" ? Lang.of(m.settings.otherLang).zh : "中文", to: Lang.of(m.dst).zh) { m.swapDirection() }
                        IconButton(symbol: "arrow.clockwise", tip: "重新翻译") { m.translate(skipCache: true) }
                        IconButton(symbol: "speaker.wave.2", tip: "朗读译文") { Speech.shared.speakAuto(m.out) }
                        IconButton(symbol: "doc.on.doc", tip: "复制译文") { copyToPasteboard(m.out) }
                    }
                    Group {
                        if case .failed(let t, let d) = m.tState {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.warn)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t).font(.system(size: 13, weight: .semibold))
                                    Text(d).font(.system(size: 12.5)).foregroundStyle(T.fg2)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(T.warnSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        } else {
                            WordText(runs: [WordRun(text: m.out, size: 15, color: T.fg),
                                            WordRun(text: m.tState == .streaming || m.tState == .loading ? "▍" : "", size: 15, color: T.amber)],
                                     lineSpacing: 8, onWord: { PopoverController.shared.peek($0) })
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
            }
        }
    }
}

struct DocPane: View {
    @ObservedObject var m = MainModel.shared

    var body: some View {
        if m.docText.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 30)).foregroundStyle(T.fg3)
                Text("翻译文档").font(.system(size: 17, weight: .semibold))
                Text("把 .txt / .md / .docx / .pdf / .rtf / .html 文件拖进窗口或上面的输入框，自动开始翻译。").foregroundStyle(T.fg2).multilineTextAlignment(.center).frame(maxWidth: 320).fixedSize(horizontal: false, vertical: true)
                KBtn(title: "选择文件…") { open() }.padding(.top, 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(T.fg2)
                    Text(m.docName).fontWeight(.medium).lineLimit(1)
                    Text("\(m.segs.count) 段").foregroundStyle(T.fg2)
                    Spacer()
                }
                .font(.system(size: 13)).padding(.horizontal, 18).padding(.top, 14)
                HStack(spacing: 8) {
                    DirPill(from: m.dst == "zh" ? Lang.of(m.settings.otherLang).zh : "中文", to: Lang.of(m.dst).zh) { m.dst = m.dst == "zh" ? m.settings.otherLang : "zh"; m.dirLocked = true }
                    Spacer(minLength: 4)
                    KBtn(title: "取消", disabled: !m.docRunning) { m.cancelDoc() }
                    KBtn(title: m.docRunning ? "翻译中…" : "重新翻译", primary: true, disabled: m.docRunning) { m.startDoc() }
                    KBtn(title: "导出…", disabled: m.docOutput.isEmpty) { export() }
                }
                .font(.system(size: 13)).padding(.horizontal, 18).padding(.top, 12)
                HStack(spacing: 12) {
                    Text(m.segs.isEmpty ? "共 0 段" : "已完成 \(m.segs.filter { $0.status == .done }.count) / \(m.segs.count) 段")
                        .font(.system(size: 12)).foregroundStyle(T.fg2).monospacedDigit()
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(T.fill2)
                            Capsule().fill(T.accent).frame(width: g.size.width * m.docProgress)
                        }
                    }.frame(height: 5)
                    Text("\(Int(m.docProgress * 100))%").font(.system(size: 12)).foregroundStyle(T.fg2).monospacedDigit()
                }
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 10)
                Sep()
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        PaneLabel(title: "原文段落")
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(m.segs) { sg in
                                    HStack(spacing: 8) {
                                        Text("\(sg.id + 1)").font(.system(size: 12.5)).foregroundStyle(T.fg3).monospacedDigit().frame(width: 22, alignment: .leading)
                                        Text(sg.src.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12.5)).foregroundStyle(T.fg2).lineLimit(1)
                                        Spacer(minLength: 4)
                                        StatusPill(status: sg.status)
                                    }
                                    .padding(.vertical, 7)
                                    .overlay(alignment: .bottom) { Sep() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8).frame(maxWidth: .infinity)
                    VSep()
                    VStack(alignment: .leading, spacing: 8) {
                        PaneLabel(title: "译文")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if m.docOutput.isEmpty {
                                    Text("译文会在这里按段落出现。").foregroundStyle(T.fg3)
                                } else {
                                    ForEach(m.segs.filter { !$0.out.isEmpty }) { sg in
                                        WordText(runs: [WordRun(text: sg.out, size: 15, color: T.fg)], lineSpacing: 8, onWord: { _ in })
                                    }
                                }
                            }
                            .font(.system(size: 15)).lineSpacing(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8).frame(maxWidth: .infinity)
                    .background(T.win2)
                }
            }
        }
    }

    func open() {
        let p = NSOpenPanel()
        p.allowedContentTypes = DocReader.extensions.compactMap { UTType(filenameExtension: $0) } + [.plainText, .text]
        if p.runModal() == .OK, let u = p.url { m.handleFile(u) }
    }
    func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "译文.txt"
        if p.runModal() == .OK, let u = p.url { try? m.docOutput.write(to: u, atomically: true, encoding: .utf8) }
    }
}

struct StatusPill: View {
    let status: DocSeg.Status
    var body: some View {
        let (t, fg, bg): (String, Color, Color) = {
            switch status {
            case .queue: return ("排队", T.fg3, T.fill)
            case .run: return ("翻译中", T.amberInk, T.amberSoft)
            case .done: return ("完成", T.ok, T.ok.opacity(0.14))
            case .failed: return ("失败", T.bad, T.badSoft)
            }
        }()
        Text(t).font(.system(size: 11.5)).foregroundStyle(fg).padding(.horizontal, 8).frame(height: 18).background(bg, in: Capsule())
    }
}

extension DictEntry {
    /// Headword + phonetics + every sense, for the copy button in the dictionary pane.
    var fullText: String {
        var lines = [headword]
        var ph: [String] = []
        if !phoneticUS.isEmpty { ph.append("美 \(phoneticUS)") }
        if !phoneticUK.isEmpty { ph.append("英 \(phoneticUK)") }
        if ph.isEmpty, !phonetic.isEmpty { ph.append(phonetic) }
        if !ph.isEmpty { lines.append(ph.joined(separator: "  ")) }
        for b in blocks {
            for (i, sn) in b.senses.enumerated() {
                let head = (i == 0 ? b.pos : "")
                let body = [sn.gloss, sn.zh].filter { !$0.isEmpty }.joined(separator: " ")
                lines.append(([head, body].filter { !$0.isEmpty }).joined(separator: " "))
                if let ex = sn.ex, !ex.isEmpty { lines.append("    " + ex) }
            }
        }
        return lines.joined(separator: "\n")
    }
}
