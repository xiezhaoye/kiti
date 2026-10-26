import AppKit
import SwiftUI
import Combine

final class KitiPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum TState: Equatable {
    case idle, loading, streaming, done
    case failed(String, String)   // title, detail
}

@MainActor
final class PopoverModel: ObservableObject {
    enum Kind { case word, capsule, translate }
    @Published var kind: Kind = .word
    @Published var text = ""
    @Published var entry: DictEntry?
    @Published var output = ""
    @Published var state: TState = .idle
    @Published var dst = "zh"
    @Published var providerUsed: Provider = .magpie
    @Published var canFallback = false
}

@MainActor
final class PopoverController {
    static let shared = PopoverController()
    let model = PopoverModel()
    private var panel: KitiPanel?
    private var host: NSHostingController<ScaleFit<PopoverView>>?
    private var sizeObs: NSKeyValueObservation?
    private var task: Task<Void, Never>?
    private var topLeft = NSPoint.zero
    private let settings = AppSettings.shared

    var isVisible: Bool { panel?.isVisible ?? false }

    func contains(_ p: NSPoint) -> Bool { panel?.frame.contains(p) ?? false }

    // MARK: show
    func show(text: String, at mouse: NSPoint) {
        let isWord = text.range(of: #"^[A-Za-z][A-Za-z'’\-]{0,40}$"#, options: .regularExpression) != nil
            || (LocalDictionary.isCJK(text) && text.count <= 4)
        cancel()
        model.text = text; model.output = ""; model.state = .idle; model.entry = nil
        if isWord {
            model.kind = .word
            model.entry = LocalDictionary.lookup(text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"“”()")))
            if let e = model.entry { MainModel.shared.addHistory(e.headword) }
        } else if settings.autoSentence {
            model.kind = .translate
            run(skipCache: false)
        } else {
            model.kind = .capsule
        }
        present(near: mouse)
        HotKeys.shared.setReturnHook(model.kind == .capsule ? { [weak self] in self?.startTranslate() } : nil)
    }

    func showTranslation(text: String, at mouse: NSPoint) {
        cancel()
        model.text = text; model.output = ""; model.entry = nil; model.kind = .translate; model.state = .idle
        run(skipCache: false)
        present(near: mouse)
        HotKeys.shared.setReturnHook(nil)
    }

    /// Double-clicked word inside the popover: show that word's entry in place.
    func lookupWord(_ w: String) {
        guard let e = LocalDictionary.lookup(w) else { HUD.show("词典里没有 “\(w)”"); return }
        model.text = w; model.entry = e; model.kind = .word
        MainModel.shared.addHistory(e.headword)
    }

    /// Double-clicked a word inside the main window: show its meaning in the popover first.
    func peek(_ word: String) {
        show(text: word, at: NSEvent.mouseLocation)
    }

    func dismiss() {
        cancel()
        HotKeys.shared.setReturnHook(nil)
        panel?.orderOut(nil)
    }

    // MARK: actions
    func startTranslate() { HotKeys.shared.setReturnHook(nil); model.kind = .translate; run(skipCache: false) }
    func redo() { run(skipCache: true) }

    func swapDirection() {
        model.dst = model.dst == "zh" ? AppSettings.shared.otherLang : "zh"
        run(skipCache: false)
    }

    func useFallback() {
        let alt: Provider? = [Provider.google, .deepl, .magpie].first { $0 != settings.provider && isConfigured($0) }
        if let alt = alt { run(skipCache: false, forced: alt) }
    }

    func isConfigured(_ p: Provider) -> Bool {
        switch p {
        case .magpie: return true
        case .google: return !settings.googleKey.isEmpty
        case .deepl: return !settings.deeplKey.isEmpty
        }
    }

    func translateWord() {
        model.kind = .translate
        run(skipCache: false)
    }

    private func cancel() { task?.cancel(); task = nil }

    private func run(skipCache: Bool, forced: Provider? = nil) {
        cancel()
        let text = model.text
        let dir = Translator.detectDirection(text, settings.direction)
        if model.kind != .translate || model.output.isEmpty { model.dst = dir.dst }
        if model.kind == .translate, forced == nil, model.state == .idle { model.dst = dir.dst }
        let dst = model.dst
        let prov = forced ?? settings.provider
        model.providerUsed = prov
        model.output = ""
        model.state = .loading
        model.canFallback = false
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await Translator.shared.translate(text, dst: dst, provider: prov, skipCache: skipCache) { [weak self] out in
                    Task { @MainActor in
                        guard let self = self, !Task.isCancelled else { return }
                        self.model.output = out
                        self.model.state = .streaming
                    }
                }
                if !Task.isCancelled { self.model.state = .done }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                let te = (error as? TranslateError) ?? .network(error.localizedDescription)
                self.model.state = .failed(te.title, te.detail)
                self.model.canFallback = [Provider.google, .deepl, .magpie].contains { $0 != prov && self.isConfigured($0) }
            }
        }
    }

    // MARK: panel
    private func present(near mouse: NSPoint) {
        if panel == nil {
            let h = NSHostingController(rootView: ScaleFit { PopoverView(model: self.model, ctl: self) })
            h.sizingOptions = [.preferredContentSize]
            let p = KitiPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.contentViewController = h
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .popUpMenu
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = p; host = h
            sizeObs = h.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.resizeKeepingTop() }
            }
        }
        host?.view.layoutSubtreeIfNeeded()
        let size = host?.preferredContentSize ?? NSSize(width: 360, height: 140)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        var x = mouse.x - 24
        var topY = mouse.y - 14                     // below the cursor
        if topY - size.height < vf.minY { topY = mouse.y + size.height + 28 }   // not enough room: flip above
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        topY = min(topY, vf.maxY - 8)
        topLeft = NSPoint(x: x, y: topY)
        panel?.setFrame(NSRect(x: x, y: topY - size.height, width: size.width, height: size.height), display: true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    private func resizeKeepingTop() {
        guard let p = panel, p.isVisible, let s = host?.preferredContentSize, s.height > 0 else { return }
        p.setFrame(NSRect(x: topLeft.x, y: topLeft.y - s.height, width: s.width, height: s.height), display: true)
    }
}

// MARK: - SwiftUI

struct SenseList: View {
    let blocks: [DictBlock]
    var limit: Int = 99
    var onWord: (String) -> Void = { _ in }
    var body: some View {
        let rows = flatten()
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 10) {
                    Text(r.pos).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(T.accent)
                        .frame(minWidth: 24, alignment: .leading).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        if !r.sense.gloss.isEmpty {
                            WordText(runs: [WordRun(text: r.sense.gloss, size: 11.5, color: T.fg2)], lineSpacing: 5, onWord: onWord)
                        }
                        if !r.sense.zh.isEmpty {
                            WordText(runs: [WordRun(text: r.sense.zh, size: 14, color: T.fg)], lineSpacing: 5.5, onWord: onWord)
                        }
                        if let ex = r.sense.ex {
                            WordText(runs: [WordRun(text: ex, size: 12, color: T.fg2)], lineSpacing: 5, onWord: onWord)
                                .padding(.leading, 10).padding(.vertical, 2)
                                .overlay(alignment: .leading) { Rectangle().fill(T.sep).frame(width: 1.5) }
                                .padding(.top, 3)
                        }
                    }
                }
            }
        }
    }
    private func flatten() -> [(pos: String, sense: DictSense)] {
        var out: [(String, DictSense)] = []
        for b in blocks { for (i, s) in b.senses.enumerated() { out.append((i == 0 ? b.pos : "", s)) } }
        return Array(out.prefix(limit))
    }
}

struct PopFooter: View {
    let source: String
    let copy: String
    let open: String
    let ctl: PopoverController
    var body: some View {
        HStack(spacing: 2) {
            Text(source).font(.system(size: 11.5)).foregroundStyle(T.fg3).lineLimit(1)
            Spacer(minLength: 8)
            IconButton(symbol: "doc.on.doc", tip: "复制") { copyToPasteboard(copy) }
            IconButton(symbol: "arrow.up.forward.square", tip: "在主窗口打开") { MainModel.shared.openWord(open); ctl.dismiss() }
        }
        .padding(.leading, 16).padding(.trailing, 8).frame(minHeight: 38)
        .overlay(alignment: .top) { Rectangle().fill(T.sep).frame(height: 0.5) }
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    let ctl: PopoverController

    var radius: CGFloat { model.kind == .capsule ? 15 : 14 }

    var body: some View {
        Group {
            switch model.kind {
            case .capsule: capsule
            case .word: word
            case .translate: translate
            }
        }
        .background(ZStack { VisualEffect(); T.glass.opacity(0.35) })
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(T.sep, lineWidth: 0.5))
        .padding(1)
    }

    var capsule: some View {
        Button { ctl.startTranslate() } label: {
            HStack(spacing: 7) {
                LogoImage().frame(width: 22, height: 22)
                Text("翻译").font(.system(size: 13, weight: .medium)).foregroundStyle(T.fg)
            }
            .padding(.leading, 4).padding(.trailing, 14).frame(height: 30)
        }
        .buttonStyle(PressStyle()).fixedSize()
    }

    var word: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.entry {
                VStack(alignment: .leading, spacing: 10) {
                    Text(e.headword).font(.system(size: 23, weight: .semibold)).foregroundStyle(T.fg)
                    PronunciationRow(entry: e, compact: true)
                }
                .padding(.horizontal, 17).padding(.top, 16).padding(.bottom, 8)
                if let info = Ecdict.info(for: e.headword), !info.chips(maxTags: 2).isEmpty {
                    ChipRow(chips: info.chips(maxTags: 2)).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 2)
                }
                SenseList(blocks: e.blocks, limit: 4, onWord: { ctl.lookupWord($0) })
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                PopFooter(source: e.source, copy: e.plain, open: e.headword, ctl: ctl)
            } else {
                Text(model.text).font(.system(size: 23, weight: .semibold)).foregroundStyle(T.fg).padding(.horizontal, 16).padding(.top, 14)
                Text("系统词典里没有这个词。").font(.system(size: 14)).foregroundStyle(T.fg2).padding(.horizontal, 16).padding(.vertical, 8)
                HStack {
                    Text("系统词典").font(.system(size: 11.5)).foregroundStyle(T.fg3)
                    Spacer()
                    KBtn(title: "翻译这个词", primary: true) { ctl.translateWord() }
                }
                .padding(.leading, 16).padding(.trailing, 8).frame(minHeight: 38)
                .overlay(alignment: .top) { Rectangle().fill(T.sep).frame(height: 0.5) }
            }
        }
        .frame(width: 360, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if let e = model.entry { MainModel.shared.openWord(e.headword); ctl.dismiss() } }   // click the card → full entry in the dictionary
    }

    var translate: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.text).font(.system(size: 12.5)).foregroundStyle(T.fg2).lineSpacing(4).lineLimit(2)
                .padding(.horizontal, 16).padding(.top, 11)
            Group {
                switch model.state {
                case .failed(let title, let detail):
                    let soft = title.contains("Magpie") || title.contains("Key")
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(soft ? T.warn : T.bad).font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.fg)
                            Text(detail).font(.system(size: 12.5)).foregroundStyle(T.fg2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(soft ? T.warnSoft : T.badSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
                case .loading, .idle:
                    Text("▍").font(.system(size: 15)).foregroundStyle(T.amber)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
                default:
                    WordText(runs: [WordRun(text: model.output, size: 15, color: T.fg),
                                    WordRun(text: model.state == .streaming ? "▍" : "", size: 15, color: T.amber)], lineSpacing: 8,
                             onWord: { ctl.lookupWord($0) })
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
                }
            }
            HStack(spacing: 2) {
                DirPill(from: model.dst == "zh" ? Lang.of(AppSettings.shared.otherLang).short : "中", to: model.dst == "zh" ? "中" : Lang.of(model.dst).short) { ctl.swapDirection() }.padding(.trailing, 8)
                Text(model.providerUsed == .magpie ? AppSettings.shared.modelShort : model.providerUsed.title)
                    .font(.system(size: 11.5)).foregroundStyle(T.fg3).lineLimit(1)
                Spacer(minLength: 6)
                if case .failed = model.state {
                    if model.canFallback { KBtn(title: "用备用服务") { ctl.useFallback() } }
                    KBtn(title: "重试", primary: true) { ctl.redo() }.padding(.leading, 4)
                } else {
                    IconButton(symbol: "arrow.clockwise", tip: "重新翻译") { ctl.redo() }
                    IconButton(symbol: "speaker.wave.2", tip: "朗读译文") { Speech.shared.speakAuto(model.output) }
                    IconButton(symbol: "doc.on.doc", tip: "复制译文") { copyToPasteboard(model.output) }
                }
            }
            .padding(.leading, 16).padding(.trailing, 8).frame(minHeight: 38)
            .overlay(alignment: .top) { Rectangle().fill(T.sep).frame(height: 0.5) }
        }
        .frame(width: 360, alignment: .leading)
    }
}

@MainActor func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    HUD.show("已复制")
}

struct SpeakButton: View {
    let label: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: "speaker.wave.2.fill").font(.system(size: 14)); Text(label).font(.system(size: 12)) }
                .foregroundStyle(T.fg2).modifier(FillPill())
        }.buttonStyle(PressStyle())
    }
}

struct IconButton: View {
    let symbol: String; let tip: String; let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 26)
                .background(hovered ? T.fill : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).foregroundStyle(T.fg2).help(tip).onHover { hovered = $0 }
    }
}

struct LogoImage: View {
    var body: some View {
        if let img = Bundle.main.image(forResource: "logo") ?? NSImage(contentsOfFile: "Resources/logo.png") {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 4))
        } else { Image(systemName: "character.book.closed") }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - HUD toast

@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var work: DispatchWorkItem?

    static func show(_ text: String) {
        let label = NSHostingView(rootView:
            Text(text).font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 9)
                .background(VisualEffect(material: .hudWindow)).clipShape(Capsule()))
        let size = label.fittingSize
        if panel == nil {
            let p = KitiPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
        }
        panel?.contentView = label
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel?.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 24, width: size.width, height: size.height), display: true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        work?.cancel()
        let w = DispatchWorkItem { NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel?.animator().alphaValue = 0 }, completionHandler: { panel?.orderOut(nil) }) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }
}

/// A transcription and its voice button are one layout unit; the main view wraps units.
struct PronunciationRow: View {
    let entry: DictEntry
    var compact = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    pronunciation(entry.phoneticUS, label: "美音", language: "en-US")
                    pronunciation(entry.phoneticUK, label: "英音", language: "en-GB")
                }
            } else {
                FlowRow(spacing: 16) {
                    pronunciation(entry.phoneticUS, label: "美音", language: "en-US")
                    pronunciation(entry.phoneticUK, label: "英音", language: "en-GB")
                }
            }
        }
    }

    private func pronunciation(_ phonetic: String, label: String, language: String) -> some View {
        HStack(spacing: 7) {
            Text(phonetic.isEmpty ? "暂无音标" : phonetic)
                .font(.system(size: compact ? 11 : 11.5, design: .monospaced)).foregroundStyle(T.fg2)
                .fixedSize(horizontal: false, vertical: true)
            SpeakButton(label: label) { Speech.shared.speak(entry.headword, lang: language) }
                .accessibilityLabel("朗读\(entry.headword)的\(label)")
        }
    }
}
