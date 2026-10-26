import Foundation
import SwiftUI

/// Collins stars, exam tags and related words, from a trimmed ECDICT (Resources/ecdict.tsv: Collins / Oxford-3000 / exam-tagged / top-40k words).
struct WordInfo {
    var collins: Int
    var oxford: Bool
    var tags: [String]
    var related: [String]

    /// Chip labels in the design's order: Collins first (amber), then the rest.
    func chips(maxTags: Int) -> [(text: String, amber: Bool)] {
        var out: [(String, Bool)] = []
        if collins > 0 { out.append(("柯林斯 " + String(repeating: "★", count: collins), true)) }
        if oxford { out.append(("牛津 3000", false)) }
        out += tags.prefix(maxTags).map { ($0, false) }
        return out
    }
}

enum Ecdict {
    private struct Row { var collins: Int; var oxford: Bool; var tag: String; var frq: Int; var exchange: String }

    private static let tagNames: [(String, String)] = [
        ("cet4", "CET-4"), ("cet6", "CET-6"), ("ky", "考研"), ("toefl", "TOEFL"), ("ielts", "IELTS"), ("gre", "GRE"), ("gk", "高考"), ("zk", "中考")
    ]

    private static let table: [String: Row] = {
        let url = Bundle.main.url(forResource: "ecdict", withExtension: "tsv") ?? URL(fileURLWithPath: "Resources/ecdict.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t: [String: Row] = [:]
        t.reserveCapacity(40000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard f.count >= 6 else { continue }
            t[f[0].lowercased()] = Row(collins: Int(f[1]) ?? 0, oxford: f[2] == "1", tag: String(f[3]), frq: Int(f[4]) ?? 0, exchange: String(f[5]))
        }
        return t
    }()

    /// Words sorted for prefix search, with a map from inflected form back to its lemma.
    private static let sorted: [String] = table.keys.sorted()
    private static let lemma: [String: String] = {
        var m: [String: String] = [:]
        for (w, r) in table {
            for part in r.exchange.split(separator: "/") {
                let kv = part.split(separator: ":", maxSplits: 1)
                guard kv.count == 2, ["p", "d", "i", "3", "s", "r", "t"].contains(String(kv[0])) else { continue }
                let form = String(kv[1])
                if form != w, table[form] == nil { m[form] = w }
            }
        }
        return m
    }()

    static func info(for headword: String) -> WordInfo? {
        let key = headword.lowercased()
        guard let word = table[key] != nil ? key : lemma[key], let row = table[word] else { return nil }
        let tags = tagNames.filter { row.tag.split(separator: " ").contains(Substring($0.0)) }.map { $0.1 }
        return WordInfo(collins: row.collins, oxford: row.oxford, tags: tags, related: related(word, row))
    }

    private static func related(_ w: String, _ row: Row) -> [String] {
        var out: [String] = []
        // derived words sharing a long stem, most frequent first
        if w.count >= 6 {
            let stem = String(w.prefix(w.count - 2))
            var i = sorted.partitionIndex { $0 >= stem }
            var hits: [(String, Int)] = []
            while i < sorted.count, sorted[i].hasPrefix(stem) {
                let c = sorted[i]
                if c != w, let r = table[c], r.frq > 0 { hits.append((c, r.frq)) }
                i += 1
            }
            out += hits.sorted { $0.1 < $1.1 }.prefix(4).map { $0.0 }
        }
        // inflections of the word itself
        for part in row.exchange.split(separator: "/") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2, ["p", "d", "i", "3", "s", "r", "t"].contains(String(kv[0])), String(kv[1]) != w, !out.contains(String(kv[1])) { out.append(String(kv[1])) }
        }
        return Array(out.prefix(6))
    }
}

private extension Array {
    /// first index whose element does not satisfy `before` being false — i.e. lower bound for a sorted array
    func partitionIndex(where pred: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi { let mid = (lo + hi) / 2; if pred(self[mid]) { hi = mid } else { lo = mid + 1 } }
        return lo
    }
}

struct ChipRow: View {
    let chips: [(text: String, amber: Bool)]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                Text(c.text).font(.system(size: 11)).lineLimit(1).fixedSize()
                    .foregroundStyle(c.amber ? T.amberInk : T.fg2)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(c.amber ? T.amberSoft : T.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }
}
