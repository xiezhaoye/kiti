import Foundation
import PDFKit

/// Extracts plain text from the document formats the translator accepts.
enum DocReader {
    static let extensions = ["txt", "md", "markdown", "rtf", "docx", "pdf", "html", "htm"]

    static func read(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": return pdf(url)
        case "docx": return docx(url)
        case "rtf", "html", "htm":
            guard let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
            return a.string
        default:
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            return try? String(contentsOf: url)
        }
    }

    // MARK: PDF — join hard-wrapped lines back into paragraphs
    private static func pdf(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var paras: [String] = []
        var cur = ""
        func flush() { let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { paras.append(t) }; cur = "" }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.string else { continue }
            for raw in page.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush(); continue }
                if cur.isEmpty { cur = line; continue }
                let endsSentence = cur.last.map { ".!?:。！？：".contains($0) } ?? false
                let startsNew = line.first.map { $0.isUppercase || $0.isNumber } ?? false
                if endsSentence && startsNew && cur.count > 40 { flush(); cur = line }
                else if cur.hasSuffix("-") { cur.removeLast(); cur += line }
                else { cur += (LocalDictionary.isCJK(line) ? "" : " ") + line }
            }
            flush()
        }
        let out = paras.joined(separator: "\n\n")
        return out.isEmpty ? nil : out
    }

    // MARK: DOCX — word/document.xml paragraphs
    private static func docx(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, var xml = String(data: data, encoding: .utf8) else { return nil }
        xml = xml.replacingOccurrences(of: "<w:tab/>", with: "\t").replacingOccurrences(of: "<w:br/>", with: "\n")
        var paras: [String] = []
        let pr = try! NSRegularExpression(pattern: "<w:p[ >].*?</w:p>", options: [.dotMatchesLineSeparators])
        let tr = try! NSRegularExpression(pattern: "<w:t(?: [^>]*)?>(.*?)</w:t>|(\\t)|(\\n)", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for m in pr.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let para = ns.substring(with: m.range) as NSString
            var line = ""
            for t in tr.matches(in: para as String, range: NSRange(location: 0, length: para.length)) {
                if t.range(at: 1).location != NSNotFound { line += para.substring(with: t.range(at: 1)) }
                else { line += para.substring(with: t.range) }
            }
            line = unescape(line).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { paras.append(line) }
        }
        let out = paras.joined(separator: "\n\n")
        return out.isEmpty ? nil : out
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
