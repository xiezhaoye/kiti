import SwiftUI
import AppKit

final class OmniTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFile: ((URL) -> Void)?
    var placeholder = ""

    override func keyDown(with e: NSEvent) {
        if (e.keyCode == 36 || e.keyCode == 76), !e.modifierFlags.contains(.shift), !hasMarkedText() { onSubmit?(); return }
        super.keyDown(with: e)
    }

    override func draw(_ r: NSRect) {
        super.draw(r)
        if string.isEmpty, !hasMarkedText() {
            placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                             withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    private func fileURL(_ pb: NSPasteboard) -> URL? {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { fileURL(s.draggingPasteboard) != nil ? .copy : super.draggingEntered(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        if let u = fileURL(s.draggingPasteboard) { onFile?(u); return true }
        return super.performDragOperation(s)
    }
    override func paste(_ sender: Any?) {
        if NSPasteboard.general.string(forType: .string) == nil, let u = fileURL(NSPasteboard.general) { onFile?(u); return }
        super.paste(sender)
    }
}

/// The one input box: grows up to `maxLines`, Return submits, Shift+Return inserts a line break, a dropped file is reported.
struct OmniInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    var minLines = 2
    var maxLines = 6
    var onSubmit: () -> Void
    var onFile: (URL) -> Void
    @Environment(\.colorScheme) private var scheme
    static let fontSize: CGFloat = 13

    final class Coord: NSObject, NSTextViewDelegate {
        var parent: OmniInput; var lastFocus = -1
        init(_ p: OmniInput) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? OmniTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            tv.needsDisplay = true
        }
    }
    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground = false; sv.hasVerticalScroller = true; sv.autohidesScrollers = true; sv.borderType = .noBorder
        let tv = OmniTextView(frame: .zero)
        tv.isRichText = false; tv.allowsUndo = true; tv.drawsBackground = false
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.delegate = context.coordinator
        tv.registerForDraggedTypes([.fileURL])
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? OmniTextView else { return }
        context.coordinator.parent = self
        tv.font = .systemFont(ofSize: Self.fontSize)
        tv.textColor = NSColor(T.fg)
        tv.insertionPointColor = NSColor(T.accent)
        tv.placeholder = placeholder
        tv.onSubmit = onSubmit; tv.onFile = onFile
        if tv.string != text { tv.string = text; tv.needsDisplay = true }
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView sv: NSScrollView, context: Context) -> CGSize? {
        guard let tv = sv.documentView as? OmniTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let w = max(proposal.width ?? 300, 40)
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let line = ceil(lm.defaultLineHeight(for: .systemFont(ofSize: Self.fontSize)))
        let h = min(max(ceil(lm.usedRect(for: tc).height) + 2, line * CGFloat(minLines)), line * CGFloat(maxLines))
        return CGSize(width: w, height: h)
    }
}
