import Foundation

enum TranslateError: Error {
    case magpieDown(String)
    case network(String)
    case provider(String)
    case missingKey(String)

    var title: String {
        switch self {
        case .magpieDown: return "Magpie 没有响应"
        case .network: return "网络连接失败"
        case .provider: return "翻译服务返回错误"
        case .missingKey: return "还没有填 API Key"
        }
    }
    var detail: String {
        switch self {
        case .magpieDown(let s), .network(let s), .provider(let s), .missingKey(let s): return s
        }
    }
}

/// Translation backends. Magpie is always direct; Google / DeepL honour the proxy setting.
final class Translator {
    static let shared = Translator()
    private let s = AppSettings.shared
    private var cache: [String: String] = [:]
    private var order: [String] = []

    // MARK: sessions
    private func session(proxied: Bool) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        if proxied, s.proxyOn, let (host, port) = parseHostPort(s.proxyHost) {
            if s.proxyType == "SOCKS5" {
                c.connectionProxyDictionary = [kCFProxyTypeKey as String: kCFProxyTypeSOCKS,
                                               "SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port]
            } else {
                c.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                                               "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
            }
        } else {
            c.connectionProxyDictionary = [:]    // never inherit the system proxy for local / unproxied traffic
        }
        return URLSession(configuration: c)
    }

    private func parseHostPort(_ s: String) -> (String, Int)? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let port = Int(p[1]) else { return nil }
        return (String(p[0]), port)
    }

    // MARK: public API
    static func detectDirection(_ text: String, _ d: Direction) -> (src: String, dst: String) {
        let o = AppSettings.shared.otherLang
        switch d {
        case .enZh: return (o, "zh")
        case .zhEn: return ("zh", o)
        case .auto: return LocalDictionary.isChinese(text) ? ("zh", o) : (o, "zh")
        }
    }

    func cached(_ text: String, dst: String, provider: Provider) -> String? { cache["\(provider.rawValue)|\(dst)|\(text)"] }

    private func store(_ text: String, dst: String, provider: Provider, out: String) {
        let k = "\(provider.rawValue)|\(dst)|\(text)"
        if cache[k] == nil { order.append(k) }
        cache[k] = out
        if order.count > 300 { cache.removeValue(forKey: order.removeFirst()) }
    }

    /// Streams the translation; `onDelta` receives the full text so far. Runs on whatever thread; callers hop to main.
    func translate(_ text: String, dst: String, provider: Provider, skipCache: Bool = false,
                   onDelta: @escaping (String) -> Void) async throws {
        if !skipCache, let hit = cached(text, dst: dst, provider: provider) { onDelta(hit); return }
        var out = ""
        switch provider {
        case .magpie:
            try await streamMagpie(text, dst: dst) { out += $0; onDelta(out) }
        case .google:
            out = try await google(text, dst: dst); onDelta(out)
        case .deepl:
            out = try await deepl(text, dst: dst); onDelta(out)
        }
        store(text, dst: dst, provider: provider, out: out)
    }

    /// English headword candidates for a Chinese term (most common first).
    func suggestEnglish(_ zh: String, provider: Provider) async throws -> [String] {
        var out = ""
        if provider == .magpie {
            let sys = "You are a Chinese-English dictionary. Give the 1 to 3 most common English words or short phrases that translate the user's Chinese term, most common first. Output only them, separated by commas, with no explanation, numbering or quotation marks."
            try await streamMagpie(zh, dst: "en", system: sys) { out += $0 }
        } else {
            try await translate(zh, dst: "en", provider: provider) { out = $0 }
        }
        let parts = out.components(separatedBy: CharacterSet(charactersIn: ",，;；\n、"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .。\"“”'‘’")) }
            .filter { !$0.isEmpty && $0.count <= 40 && !LocalDictionary.isCJK($0) }
        var seen = Set<String>()
        return parts.filter { seen.insert($0.lowercased()).inserted }.prefix(3).map { $0 }
    }

    // MARK: Magpie (OpenAI-compatible SSE)
    private func streamMagpie(_ text: String, dst: String, system: String? = nil, onChunk: @escaping (String) -> Void) async throws {
        let base = s.magpieURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/v1/chat/completions") else { throw TranslateError.magpieDown("地址无效：\(s.magpieURL)") }
        let target = Lang.of(dst).english
        let custom = s.llmPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let sys = system ?? (custom.isEmpty
            ? "You are a translation engine. Translate the user's text into \(target). Output only the translation, with no preface, notes or quotation marks. Keep paragraph breaks."
            : custom.replacingOccurrences(of: "{target}", with: target))
        let body: [String: Any] = ["model": s.model, "stream": true, "temperature": s.llmTemp,
                                   "messages": [["role": "system", "content": sys], ["role": "user", "content": text]]]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !s.llmKey.isEmpty { req.setValue("Bearer \(s.llmKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        do {
            let (bytes, resp) = try await session(proxied: llmViaProxy(url)).bytes(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                var msg = ""
                for try await line in bytes.lines { msg += line; if msg.count > 300 { break } }
                throw TranslateError.provider("HTTP \(http.statusCode) \(msg)")
            }
            var got = false
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let d = payload.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let ch = (j["choices"] as? [[String: Any]])?.first,
                      let delta = ch["delta"] as? [String: Any],
                      let c = delta["content"] as? String, !c.isEmpty else { continue }
                got = true
                onChunk(c)
            }
            if !got { throw TranslateError.provider("模型没有返回内容") }
        } catch let e as TranslateError {
            throw e
        } catch let e as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(e.code) {
            throw TranslateError.magpieDown("\(base) 无法连接。词典查询不受影响。")
        } catch {
            throw TranslateError.network(error.localizedDescription)
        }
    }

    // MARK: Google Cloud Translation v2
    private func google(_ text: String, dst: String) async throws -> String {
        guard !s.googleKey.isEmpty else { throw TranslateError.missingKey("在设置 → 翻译 API 里填入 Google 翻译 API Key。") }
        var comps = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        comps.queryItems = [URLQueryItem(name: "key", value: s.googleKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["q": text, "target": Lang.of(dst).google, "format": "text"])
        let data = try await send(req)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = ((j["data"] as? [String: Any])?["translations"] as? [[String: Any]])?.first?["translatedText"] as? String
        else { throw TranslateError.provider(String(data: data, encoding: .utf8) ?? "无法解析返回内容") }
        return t
    }

    // MARK: DeepL
    private func deepl(_ text: String, dst: String) async throws -> String {
        guard !s.deeplKey.isEmpty else { throw TranslateError.missingKey("在设置 → 翻译 API 里填入 DeepL API Key。") }
        let host = s.deeplKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var req = URLRequest(url: URL(string: "https://\(host)/v2/translate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("DeepL-Auth-Key \(s.deeplKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": [text], "target_lang": Lang.of(dst).deepl])
        let data = try await send(req)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = (j["translations"] as? [[String: Any]])?.first?["text"] as? String
        else { throw TranslateError.provider(String(data: data, encoding: .utf8) ?? "无法解析返回内容") }
        return t
    }

    private func send(_ req: URLRequest) async throws -> Data {
        var r = req
        r.timeoutInterval = 8
        do {
            let (data, resp) = try await session(proxied: true).data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                throw TranslateError.provider("HTTP \(h.statusCode) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            }
            return data
        } catch let e as TranslateError {
            throw e
        } catch {
            let via = s.proxyOn ? "已通过 \(s.proxyType) \(s.proxyHost) 尝试。检查代理软件是否在运行。" : "没有设置代理，走的直连。可以在设置里开启代理。"
            throw TranslateError.network("\(via)（\(error.localizedDescription)）")
        }
    }

    /// Local gateways are always direct; a remote LLM endpoint goes through the proxy only when the user asks for it.
    func llmViaProxy(_ url: URL) -> Bool {
        let h = url.host ?? ""
        let local = h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".local")
        return s.llmProxy && !local
    }

    /// One-shot connectivity check used by the settings screen; returns a human-readable result.
    func test(_ provider: Provider) async -> String {
        let t0 = Date()
        var out = ""
        do {
            try await translate("Hello, world.", dst: "zh", provider: provider, skipCache: true) { out = $0 }
            return "可用 · \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒 · “\(out.prefix(24))”"
        } catch let e as TranslateError {
            return "\(e.title)：\(e.detail.prefix(120))"
        } catch { return error.localizedDescription }
    }

    /// Quick reachability probe for the settings screen.
    func testProxy() async -> String {
        guard s.proxyOn else { return "代理已关闭，将直连" }
        var req = URLRequest(url: URL(string: "https://translation.googleapis.com/generate_204")!)
        req.timeoutInterval = 6
        do { _ = try await session(proxied: true).data(for: req); return "代理可用" }
        catch { return "连接失败：\(error.localizedDescription)" }
    }
}
