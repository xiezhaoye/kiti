import CoreServices
import Foundation

@_silgen_name("DCSCopyAvailableDictionaries") private func _availableDictionaries() -> Unmanaged<CFSet>?
@_silgen_name("DCSDictionaryGetName") private func _dictionaryName(_ d: DCSDictionary) -> Unmanaged<CFString>?
@_silgen_name("DCSCopyRecordsForSearchString") private func _records(_ d: DCSDictionary, _ s: CFString, _ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?) -> Unmanaged<CFArray>?
@_silgen_name("DCSRecordGetHeadword") private func _headword(_ r: CFTypeRef) -> Unmanaged<CFString>?
@_silgen_name("DCSRecordCopyData") private func _recordData(_ r: CFTypeRef, _ version: Int) -> Unmanaged<CFString>?

struct DictSense {
    var gloss: String      // e.g. "(basic reasons)"
    var zh: String
    var ex: String?
}

struct DictBlock {
    var pos: String        // n. / v. / adj. …
    var senses: [DictSense]
}

struct DictEntry {
    var headword: String
    var phonetic: String
    var blocks: [DictBlock]
    var source: String
    var phoneticUS: String = ""
    var phoneticUK: String = ""

    var plain: String {
        headword + "\n" + blocks.map { b in b.senses.map { "\(b.pos) \($0.gloss) \($0.zh)" }.joined(separator: "\n") }.joined(separator: "\n")
    }
    var senseCount: Int { blocks.reduce(0) { $0 + $1.senses.count } }
}

enum LocalDictionary {
    private static let oxford: DCSDictionary? = {
        guard let set = _availableDictionaries()?.takeRetainedValue() as? Set<AnyHashable> else { return nil }
        for d in set {
            let dict = d as! DCSDictionary
            if let n = _dictionaryName(dict)?.takeUnretainedValue() as String?, n.contains("牛津英汉汉英") { return dict }
        }
        return nil
    }()

    /// CJK ideographs without kana/hangul — i.e. Chinese rather than Japanese/Korean.
    static func isChinese(_ s: String) -> Bool {
        isCJK(s) && !s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    static func isCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func lookup(_ word: String) -> DictEntry? {
        let ns = word as NSString
        let ascii = !isCJK(word)
        // 1) exact headword record (avoids fuzzy pinyin hits such as run -> 闰)
        if let ox = oxford, let arr = _records(ox, word as CFString, nil, nil)?.takeRetainedValue() as? [CFTypeRef] {
            let key = word.lowercased()
            let hit = arr.first { r in
                let h = (_headword(r)?.takeUnretainedValue() as String?)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                return h == key
            }
            if let r = hit, let t = _recordData(r, 3)?.takeRetainedValue() as String?, !t.isEmpty { return parse(t, query: word) }
        }
        // 2) fallback: dictionary service best match (inflections such as running -> run)
        let range = CFRange(location: 0, length: ns.length)
        let raw: String?
        if let ox = oxford, let r = DCSCopyTextDefinition(ox, ns, range) { raw = r.takeRetainedValue() as String }
        else if let r = DCSCopyTextDefinition(nil, ns, range) { raw = r.takeRetainedValue() as String }
        else { raw = nil }
        guard let text = raw, !text.isEmpty else { return nil }
        if ascii, text.components(separatedBy: " | ").count < 3 { return nil }
        return parse(text, query: word)
    }

    // MARK: parsing the Oxford text blob into pos blocks / senses / examples

    private static let posMap: [(String, String)] = [
        ("transitive verb", "vt."), ("intransitive verb", "vi."), ("phrasal verb", "phr."), ("auxiliary verb", "aux."), ("modal verb", "modal"),
        ("noun", "n."), ("verb", "v."), ("adjective", "adj."), ("adverb", "adv."), ("preposition", "prep."), ("conjunction", "conj."),
        ("pronoun", "pron."), ("exclamation", "int."), ("interjection", "int."), ("determiner", "det."), ("abbreviation", "abbr."),
        ("prefix", "pref."), ("suffix", "suf.")
    ]
    private static let tone = "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜńňḿ"
    private static let neutral: Set<String> = ["de", "le", "ma", "ne", "ba", "zi", "men", "zhe", "guo", "tou", "li", "shang", "xia", "ge", "me", "ya", "a"]
    private static let pinyinRun: NSRegularExpression = {
        let tok = "[a-zü\(tone)]+"
        return try! NSRegularExpression(pattern: "(?<=[\\u4e00-\\u9fff…/])\\s?\(tok)(?:\\s\(tok))*")
    }()

    static func stripPinyin(_ s: String) -> String {
        var out = s
        let ms = pinyinRun.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for m in ms {
            guard let r = Range(m.range, in: out) else { continue }
            let run = out[r].trimmingCharacters(in: .whitespaces)
            let hasTone = run.unicodeScalars.contains { tone.unicodeScalars.contains($0) }
            if hasTone || neutral.contains(run) { out.replaceSubrange(r, with: "") }
        }
        return out
    }

    static func parse(_ text: String, query: String) -> DictEntry {
        let parts = text.components(separatedBy: " | ")
        var head = query, phon = "", rest = text
        if parts.count >= 3 {
            head = parts[0].trimmingCharacters(in: .whitespaces)
            phon = phonetic(parts[1])
            rest = parts[2...].joined(separator: " | ")
        }
        // "abuse A. transitive verb" → "abuse"; everything after a "PHRASAL VERB" marker is phrasal-verb sections
        head = head.replacingOccurrences(of: "\\s+[A-Z]\\.\\s.*$", with: "", options: .regularExpression)
        if let r = rest.range(of: "PHRASAL VERB") { rest = String(rest[..<r.lowerBound]) }
        var blocks = splitPOS(rest)
        if blocks.isEmpty {
            let z = stripPinyin(rest).trimmingCharacters(in: .whitespacesAndNewlines)
            blocks = [DictBlock(pos: "", senses: [DictSense(gloss: "", zh: z, ex: nil)])]
        }
        blocks = dropPhrasal(blocks, head: head)
        var entry = DictEntry(headword: head, phonetic: phon, blocks: blocks, source: "系统词典 · 牛津英汉汉英")
        if parts.count >= 3 {
            entry.phoneticUS = regionalPhonetic(parts[1], tag: "AmE")
            entry.phoneticUK = regionalPhonetic(parts[1], tag: "BrE")
        }
        return entry
    }

    /// Large verb entries append their phrasal verbs (run across / run after …) after the core senses; cut from the first one.
    private static func dropPhrasal(_ blocks: [DictBlock], head: String) -> [DictBlock] {
        let h = NSRegularExpression.escapedPattern(for: head.lowercased())
        let parts = "across|after|along|around|about|ahead|against|apart|at|away|back|behind|by|down|for|forward|from|in|into|off|on|out|over|round|through|to|up|upon|with"
        guard let re = try? NSRegularExpression(pattern: "(?:\\[|=\\s*|^\\s*(?:to )?)\(h) (?:(?:sth|sb|sth/sb|oneself) )?(?:\(parts))(?![A-Za-z-])", options: .caseInsensitive) else { return blocks }
        func hit(_ t: String) -> Bool { re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
        var out: [DictBlock] = []
        for b in blocks {
            guard let i = b.senses.firstIndex(where: { hit($0.gloss) || hit($0.zh) }) else { out.append(b); continue }
            if i > 0 { out.append(DictBlock(pos: b.pos, senses: Array(b.senses[..<i]))) }
            return out
        }
        return out
    }

    /// Keep each regional transcription (including comma-separated alternatives).
    /// Untagged pronunciations are shared; a missing tagged region stays empty.
    private static func regionalPhonetic(_ s: String, tag: String) -> String {
        let tags = ["BrE", "AmE"]
        guard let start = s.range(of: tag + " ") else {
            return tags.contains(where: { s.contains($0) }) ? "" : phonetic(s)
        }
        var tail = String(s[start.upperBound...])
        for other in tags where other != tag {
            if let end = tail.range(of: other) { tail = String(tail[..<end.lowerBound]) }
        }
        let value = tail.trimmingCharacters(in: CharacterSet(charactersIn: " ,;\n\t"))
        return value.isEmpty ? "" : "/" + value + "/"
    }

    private static func phonetic(_ s: String) -> String {
        for tag in ["AmE", "BrE"] {
            if let r = s.range(of: tag + " ") {
                let tail = s[r.upperBound...]
                let v = tail.split(whereSeparator: { $0 == "," || $0 == ";" }).first.map(String.init) ?? String(tail)
                return "/" + v.trimmingCharacters(in: .whitespaces) + "/"
            }
        }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : "/" + t + "/"
    }

    private static func splitPOS(_ rest: String) -> [DictBlock] {
        // find POS markers at paren depth 0
        let chars = Array(rest)
        var depth = 0
        var marks: [(idx: Int, len: Int, abbr: String)] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "（" { depth += 1 } else if c == ")" || c == "）" { depth = max(0, depth - 1) }
            if depth == 0, i == 0 || chars[i - 1] == " " {
                for (name, abbr) in posMap {
                    let n = Array(name)
                    if i + n.count <= chars.count, Array(chars[i..<(i + n.count)]) == n,
                       i + n.count == chars.count || chars[i + n.count] == " " {
                        marks.append((i, n.count, abbr)); i += n.count - 1; break
                    }
                }
            }
            i += 1
        }
        guard !marks.isEmpty else { return [] }
        var out: [DictBlock] = []
        for (k, m) in marks.enumerated() {
            let end = k + 1 < marks.count ? marks[k + 1].idx : chars.count
            let body = String(chars[(m.idx + m.len)..<end])
            let senses = parseSenses(body)
            if !senses.isEmpty { out.append(DictBlock(pos: m.abbr, senses: senses)) }
        }
        return out
    }

    private static let noise: [NSRegularExpression] = [
        "present participle \\S+", "past tense \\S+", "past participle \\S+", "third person singular \\S+",
        "plural \\S+", "comparative \\S+", "superlative \\S+", "(?<![A-Za-z])[A-F]\\.(?=\\s|$)"
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func parseSenses(_ rawBody: String) -> [DictSense] {
        var body = rawBody
        for re in noise { body = re.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "") }
        // sense segments are introduced by ①②…; otherwise the whole body is one segment
        var segs: [String] = []
        var cur = ""
        var sawNumber = false
        for ch in body {
            if let v = ch.unicodeScalars.first?.value, ((0x2460...0x2473).contains(v) || (0x3251...0x325F).contains(v) || (0x32B1...0x32BF).contains(v)) {
                // text before the first ① is just a usage label (e.g. "formal") when it has no Chinese
                if !cur.trimmingCharacters(in: .whitespaces).isEmpty, sawNumber || isCJK(cur) { segs.append(cur) }
                cur = ""; sawNumber = true
            } else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { segs.append(cur) }
        var out: [DictSense] = []
        for seg in segs {
            let pieces = seg.components(separatedBy: "▸")
            let head = pieces[0]
            let exs = pieces.dropFirst().map { stripPinyin($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var items = splitTop(head, on: ";")
            if items.isEmpty { items = [head] }
            for (j, it) in items.enumerated() {
                let clean = stripPinyin(it).trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty { continue }
                var gloss = "", zh = clean
                if let r = clean.unicodeScalars.firstIndex(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                    gloss = String(clean.unicodeScalars[..<r]).trimmingCharacters(in: .whitespaces)
                    zh = String(clean.unicodeScalars[r...])
                    if gloss.hasSuffix("[") { gloss = String(gloss.dropLast()).trimmingCharacters(in: .whitespaces); zh = "[" + zh }
                }
                zh = tidy(zh)
                let ex = j == items.count - 1 ? tidyTail(exs.prefix(2).joined(separator: "\n")) : ""
                out.append(DictSense(gloss: gloss, zh: zh.trimmingCharacters(in: CharacterSet(charactersIn: "; ")), ex: ex.isEmpty ? nil : ex))
            }
        }
        return out
    }

    /// Chinese usage notes come as "[…]"; show them as （…） and cut the next phrase's header that sticks to the end ("… add to:", "K. all round").
    private static func tidy(_ s: String) -> String {
        var z = s.replacingOccurrences(of: "[", with: "（").replacingOccurrences(of: "]", with: "）")
        z = z.replacingOccurrences(of: "）（", with: "；").replacingOccurrences(of: "（）", with: "")
        return tidyTail(z)
    }

    private static let tailJunk: [NSRegularExpression] = [
        "\\s+[A-Za-z][A-Za-z ,'/]{1,30}:\\s*$",
        "\\s+[A-Z]\\.\\s+[a-z].*$",
        "(?<=[\\u4e00-\\u9fff）])\\s{2,}[A-Za-z][A-Za-z ,'/-]{1,40}$",
        "(?<=[›\\u4e00-\\u9fff）])\\s+[a-z][a-z'/-]*(?: [A-Za-z'/-]+){1,6}$",
        "\\s*[:：]\\s*$"
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func tidyTail(_ s: String) -> String {
        var z = s
        for re in tailJunk { z = re.stringByReplacingMatches(in: z, range: NSRange(z.startIndex..., in: z), withTemplate: "") }
        return z.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// split on a separator outside parentheses/brackets
    private static func splitTop(_ s: String, on sep: Character) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        for c in s {
            if "(（‹[".contains(c) { depth += 1 } else if ")）›]".contains(c) { depth = max(0, depth - 1) }
            if c == sep, depth == 0 { out.append(cur); cur = "" } else { cur.append(c) }
        }
        out.append(cur)
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
