import SwiftUI
import AppKit

/// Selectable text whose double-clicked English word is reported (used to jump to that word in the dictionary).
final class WordTextView: NSTextView {
    var onWord: ((String) -> Void)?

}

struct WordRun {
    var text: String
    var size: CGFloat
    var color: Color
    var weight: NSFont.Weight = .regular
}

struct WordText: NSViewRepresentable {
    let runs: [WordRun]
    var lineSpacing: CGFloat = 5
    var onWord: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    private var attributed: NSAttributedString {
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = lineSpacing
        let out = NSMutableAttributedString()
        for r in runs {
            out.append(NSAttributedString(string: r.text, attributes: [
                .font: NSFont.systemFont(ofSize: r.size, weight: r.weight),
                .foregroundColor: NSColor(r.color), .paragraphStyle: ps]))
        }
        return out
    }

    func makeNSView(context: Context) -> WordTextView {
        let tv = WordTextView(frame: .zero)
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false; tv.isHorizontallyResizable = false
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateNSView(_ tv: WordTextView, context: Context) {
        tv.onWord = onWord
        let a = attributed
        if !tv.attributedString().isEqual(to: a) { tv.textStorage?.setAttributedString(a) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: WordTextView, context: Context) -> CGSize? {
        let w = max(proposal.width ?? 360, 20)
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return CGSize(width: w, height: ceil(lm.usedRect(for: tc).height))
    }
}

/// Wrapping row of equally spaced items.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 400, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in arrange(bounds.width, subviews).frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowH))
    }
}
