import AppKit
import UniformTypeIdentifiers

struct ArticleItem: Codable, Hashable, Identifiable {
    var id: String
    var src: String
    var out: String
    var dst: String
    var t: Date
}

struct DocItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var text: String
    var outs: [String]
    var dst: String
    var t: Date
}

struct HistoryData: Codable {
    var words: [HItem] = []
    var articles: [ArticleItem] = []
    var docs: [DocItem] = []
}

/// History lives in one JSON file; every item has a stable key, so files from several machines merge without conflicts.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    static let capWords = 1000, capArticles = 500, capDocs = 50

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("kiti")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    private(set) var data = HistoryData()
    var onExternalChange: (() -> Void)?

    init() {
        let dec = Self.decoder
        if let d = try? Data(contentsOf: file), let h = try? dec.decode(HistoryData.self, from: d) { data = h }
        else if let old = UserDefaults.standard.data(forKey: "history2"), let w = try? JSONDecoder().decode([HItem].self, from: old) {
            data.words = w   // migrate from the first version
        }
    }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    func save(_ d: HistoryData) {
        data = d
        if let j = try? Self.encoder.encode(d) { try? j.write(to: file, options: .atomic) }
    }

    // MARK: merge
    static func merged(_ a: HistoryData, _ b: HistoryData) -> HistoryData {
        var words: [String: HItem] = [:]
        for h in a.words + b.words {
            let k = h.w.lowercased()
            if let o = words[k], o.t <= h.t { continue }      // a word keeps its first lookup
            words[k] = h
        }
        var arts: [String: ArticleItem] = [:]
        for x in a.articles + b.articles { if let o = arts[x.id], o.t >= x.t { continue }; arts[x.id] = x }
        var docs: [String: DocItem] = [:]
        for x in a.docs + b.docs { if let o = docs[x.id], o.t >= x.t { continue }; docs[x.id] = x }
        return HistoryData(
            words: Array(words.values.sorted { $0.t > $1.t }.prefix(capWords)),
            articles: Array(arts.values.sorted { $0.t > $1.t }.prefix(capArticles)),
            docs: Array(docs.values.sorted { $0.t > $1.t }.prefix(capDocs)))
    }

    func merge(_ other: HistoryData) {
        save(Self.merged(data, other))
        onExternalChange?()
    }

    // MARK: export / import
    func exportFile() {
        let p = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        p.nameFieldStringValue = "kiti-history-\(f.string(from: Date())).json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url, let j = try? Self.encoder.encode(data) else { return }
        do { try j.write(to: u, options: .atomic); HUD.show("已导出 \(data.words.count) 个词、\(data.articles.count) 篇、\(data.docs.count) 份文档") }
        catch { HUD.show("导出失败：\(error.localizedDescription)") }
    }

    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url else { return }
        guard let d = try? Data(contentsOf: u), let h = try? Self.decoder.decode(HistoryData.self, from: d) else { HUD.show("这不是 kiti 的历史记录文件"); return }
        merge(h)
        HUD.show("已导入 \(h.words.count) 个词、\(h.articles.count) 篇、\(h.docs.count) 份文档")
    }

    // MARK: folder sync (NAS / shared folder): each machine writes only its own file and merges everyone else's
    var syncFolder: String { get { UserDefaults.standard.string(forKey: "syncFolder") ?? "" } set { UserDefaults.standard.set(newValue, forKey: "syncFolder") } }
    private var deviceID: String {
        if let d = UserDefaults.standard.string(forKey: "deviceID") { return d }
        let d = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(d, forKey: "deviceID"); return d
    }

    @discardableResult
    func syncNow() -> String {
        guard !syncFolder.isEmpty else { return "未设置同步文件夹" }
        let dir = URL(fileURLWithPath: syncFolder)
        guard FileManager.default.fileExists(atPath: dir.path) else { return "找不到文件夹（NAS 是否已连接？）" }
        let mine = "kiti-history-\(deviceID).json"
        var pulled = 0
        var all = data
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where u.lastPathComponent.hasPrefix("kiti-history-") && u.pathExtension == "json" && u.lastPathComponent != mine {
            if let d = try? Data(contentsOf: u), let h = try? Self.decoder.decode(HistoryData.self, from: d) { all = Self.merged(all, h); pulled += 1 }
        }
        save(all)
        onExternalChange?()
        do { try Self.encoder.encode(all).write(to: dir.appendingPathComponent(mine), options: .atomic) }
        catch { return "写入失败：\(error.localizedDescription)" }
        let f = DateFormatter(); f.dateFormat = "H:mm:ss"
        return "已同步（合并 \(pulled) 台设备）· \(f.string(from: Date()))"
    }

    func chooseSyncFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.message = "选择一个所有设备都能访问的文件夹（例如挂载的 NAS 共享目录）"
        if p.runModal() == .OK, let u = p.url { syncFolder = u.path }
    }
}
