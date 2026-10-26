import AppKit
import SwiftUI

/// Approved UI tokens from designs/kiti-ui-review (light + dark, specified at 1×).
func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum T {
    static let footerHeight: CGFloat = 32

    static let win = Color(light: rgba(0xfbfcfe), dark: rgba(0x242931))
    static let win2 = Color(light: rgba(0xeff2f7), dark: rgba(0x292f39))
    static let side = Color(light: rgba(0xeff2f7), dark: rgba(0x20252d))
    static let fg = Color(light: rgba(0x222b38), dark: rgba(0xe8edf5))
    static let fg2 = Color(light: rgba(0x687486), dark: rgba(0xa7b1c1))
    static let fg3 = Color(light: rgba(0x7b8796), dark: rgba(0x949fb0))
    static let sep = Color(light: rgba(0xdce2eb), dark: rgba(0x3b4350))
    static let fill = Color(light: rgba(0xe9edf3), dark: rgba(0x323a47))
    static let fill2 = Color(light: rgba(0xdfe9f7), dark: rgba(0x334763))
    static let field = Color(light: rgba(0xffffff), dark: rgba(0x292f39))
    static let accent = Color(light: rgba(0x315f9c), dark: rgba(0x9dbfee))
    static let accentFg = Color(light: rgba(0xffffff), dark: rgba(0x172a43))
    static let amberInk = Color(light: rgba(0x8a5200), dark: rgba(0xf7b94a))
    static let amberSoft = Color(light: rgba(0xf59e0b, 0.17), dark: rgba(0xf59e0b, 0.2))
    static let amber = Color(rgba(0xf59e0b))
    static let ok = Color(light: rgba(0x2d7855), dark: rgba(0x87c9a9))
    static let warn = Color(light: rgba(0x9a5b00), dark: rgba(0xf0b04a))
    static let warnSoft = Color(light: rgba(0xf59e0b, 0.16), dark: rgba(0xf59e0b, 0.17))
    static let bad = Color(light: rgba(0xc43a32), dark: rgba(0xff7a70))
    static let badSoft = Color(light: rgba(0xc43a32, 0.11), dark: rgba(0xff7a70, 0.14))
    static let glass = Color(light: rgba(0xfafbfd, 0.74), dark: rgba(0x2c2e34, 0.74))
}

extension Color { init(_ ns: NSColor) { self.init(nsColor: ns) } }

/// Pill-ish small button used for 美/英 and direction.
struct FillPill: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 9).frame(height: 24).background(T.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The design's `.btn` (and `.btn.p` for the primary one).
struct KBtn: View {
    let title: String
    var primary = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: primary ? .medium : .regular)).lineLimit(1).fixedSize()
                .foregroundStyle(primary ? T.accentFg : T.fg)
                .padding(.horizontal, 11).frame(height: 24)
                .background(primary ? AnyShapeStyle(T.accent) : AnyShapeStyle(T.field), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(primary ? .clear : T.sep, lineWidth: 0.5))
        }
        .buttonStyle(PressStyle()).disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}

/// Segmented control drawn like the design's `.seg`.
struct KSeg<V: Hashable>: View {
    var height: CGFloat = 22
    let items: [(V, String)]
    @Binding var sel: V
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button { sel = it.0 } label: {
                    Text(it.1).font(.system(size: 13, weight: sel == it.0 ? .medium : .regular))
                        .foregroundStyle(sel == it.0 ? T.fg : T.fg2)
                        .padding(.horizontal, 12).frame(height: height)
                        .background(sel == it.0 ? T.field : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .shadow(color: sel == it.0 ? .black.opacity(0.18) : .clear, radius: 1.5, y: 0.5)
                }.buttonStyle(.plain)
            }
        }
        .padding(2).background(T.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct DirPill: View {
    let from: String, to: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { Text(from); Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .semibold)); Text(to) }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(T.fg).modifier(FillPill())
        }.buttonStyle(PressStyle())
    }
}

struct Kbd: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(T.fg2)
            .frame(minWidth: 18).frame(height: 18).padding(.horizontal, 4)
            .background(T.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The design is specified in CSS px and meant to be viewed at roughly 1.3x; `uiScale` applies that to every kiti surface.
struct ScaleFill<C: View>: View {
    @ObservedObject var s = AppSettings.shared
    @ViewBuilder let content: () -> C
    var body: some View {
        GeometryReader { g in
            let k = CGFloat(s.uiScale)
            content().frame(width: g.size.width / k, height: g.size.height / k)
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }.ignoresSafeArea()
    }
}

/// Measure intrinsic content synchronously, so a newly-created floating panel never
/// reports a zero-sized frame while waiting for a geometry preference update.
private struct ScaledIntrinsicLayout: Layout {
    let scale: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(.unspecified)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

/// Preserve intrinsic sizing and the same uiScale as the main and settings windows.
struct ScaleFit<C: View>: View {
    @ObservedObject var s = AppSettings.shared
    @ViewBuilder let content: () -> C
    var body: some View {
        let k = CGFloat(s.uiScale)
        ScaledIntrinsicLayout(scale: k) {
            content().fixedSize().scaleEffect(k, anchor: .topLeading)
        }
    }
}
