import SwiftUI
import AppKit
import Combine

/// Spotlight-style quick lookup: a small floating search field; Return opens the main window with that query.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { QuickQuery.hide() }
}

private struct QuickView: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(T.fg2)
            TextField("lingo，查询，翻译一句话", text: $text)
                .textFieldStyle(.plain).font(.system(size: 18)).focused($focused)
                .onSubmit { QuickQuery.commit(text) }
        }
        .padding(.horizontal, 16).frame(width: 460, height: 52)
        .background(VisualEffect(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(T.sep, lineWidth: 0.5))
        .onAppear { text = ""; DispatchQueue.main.async { focused = true } }
    }
}

@MainActor
enum QuickQuery {
    private static var panel: QuickPanel?
    private static var resign: NSObjectProtocol?

    static func toggle() {
        if let p = panel, p.isVisible { hide() } else { show() }
    }

    static func show() {
        let host = NSHostingView(rootView: ScaleFit { QuickView() })
        let size = host.fittingSize
        let p = QuickPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - vf.height * 0.3 - size.height, width: size.width, height: size.height), display: true)
        panel?.orderOut(nil)
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            Task { @MainActor in QuickQuery.hide() }
        }
    }

    static func hide() {
        if let r = resign { NotificationCenter.default.removeObserver(r); resign = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    static func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        hide()
        guard !t.isEmpty else { return }
        MainModel.shared.input = t
        MainWindow.show()
        MainModel.shared.submit()
    }
}

/// Shared display-scale vocabulary. New 100% is 90% of the original 1.3 baseline.
enum UIScale {
    static let standard: Double = 1.17
    static let steps: [Double] = [0.702, 0.8775, 1.053, 1.17, 1.3455, 1.521, 1.755]
    static let labels: [(Double, String)] = [(0.702, "60%"), (0.8775, "75%"), (1.053, "90%"), (1.17, "100%（默认）"), (1.3455, "115%"), (1.521, "130%"), (1.755, "150%")]
    static func nearest(_ value: Double) -> Double {
        steps.min { abs($0 - value) < abs($1 - value) } ?? standard
    }
}

/// Keeps a window's size in step with `uiScale` (settings change or ⌥+/⌥−).
@MainActor
enum ScaleSync {
    static let steps = UIScale.steps
    static let labels = UIScale.labels
    private static var bag: [ObjectIdentifier: [Any]] = [:]

    static func step(_ dir: Int) {
        let s = AppSettings.shared
        let cur = steps.enumerated().min { abs($0.element - s.uiScale) < abs($1.element - s.uiScale) }?.offset ?? 3
        let next = min(max(cur + dir, 0), steps.count - 1)
        s.uiScale = steps[next]
    }

    /// `base`: the window's size at uiScale 1 (settings: fixed); `minBase`: its minimum size at uiScale 1.
    /// The window's size is remembered in scale-free units, so shrinking and growing again returns to the same layout.
    static func bind(_ w: NSWindow, base: NSSize, minBase: NSSize? = nil, fixed: Bool) {
        var last = CGFloat(AppSettings.shared.uiScale)
        var design = NSSize(width: w.contentRect(forFrameRect: w.frame).width / last, height: w.contentRect(forFrameRect: w.frame).height / last)
        var programmatic = false
        let resize = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak w] _ in
            guard let w = w, !programmatic, !fixed else { return }
            let c = w.contentRect(forFrameRect: w.frame).size
            design = NSSize(width: c.width / last, height: c.height / last)
        }
        let sink = AppSettings.shared.$uiScale.dropFirst().receive(on: DispatchQueue.main).sink { [weak w] _ in
            guard let w = w else { return }
            let k = CGFloat(AppSettings.shared.uiScale)
            guard k != last else { return }
            last = k
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            let d = fixed ? base : design
            var size = NSSize(width: d.width * k, height: d.height * k)
            size.width = min(size.width, vis.width * 0.96); size.height = min(size.height, vis.height * 0.96)
            programmatic = true
            if let m = minBase { w.contentMinSize = NSSize(width: m.width * k, height: m.height * k) }
            var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
            w.setFrame(f, display: true, animate: false)
            programmatic = false
        }
        bag[ObjectIdentifier(w)] = [resize, sink]
    }
}
