import Foundation

// MARK: - Pricing (API list prices, USD per million tokens)

struct Price {
    let input: Double
    let output: Double
    var cacheRead: Double? = nil
}

enum Pricing {
    /// Matched by longest prefix of the model id. Subscription plans aren't billed per token;
    /// these rates turn Claude Code token counts into an "API-equivalent" cost.
    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-opus-5-5", Price(input: 4, output: 20)),
        ("claude-opus-5", Price(input: 5, output: 25)),
        ("claude-opus-4-8", Price(input: 5, output: 25)),
        ("claude-opus-4-7", Price(input: 5, output: 25)),
        ("claude-opus-4-6", Price(input: 5, output: 25)),
        ("claude-opus-4-5", Price(input: 5, output: 25)),
        ("claude-opus-4", Price(input: 15, output: 75)),
        ("claude-3-opus", Price(input: 15, output: 75)),
        ("claude-sonnet-5", Price(input: 2, output: 10)),
        ("claude-sonnet-4", Price(input: 3, output: 15)),
        ("claude-3-7-sonnet", Price(input: 3, output: 15)),
        ("claude-3-5-sonnet", Price(input: 3, output: 15)),
        ("claude-haiku-4-5", Price(input: 1, output: 5)),
        ("claude-3-5-haiku", Price(input: 0.8, output: 4)),
        ("claude-3-haiku", Price(input: 0.25, output: 1.25)),
    ]

    static func price(for model: String) -> Price? {
        table.filter { model.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.price
    }

    static let fallback = Price(input: 3, output: 15)
}

// MARK: - Parsed data

struct CodeEntry {
    let sessionId: String
    let timestamp: Date
    let model: String
    let cwd: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int

    var tokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    var price: Price { Pricing.price(for: model) ?? Pricing.fallback }

    var cost: Double {
        let p = price
        let read = p.cacheRead ?? p.input * 0.1
        return (Double(input) * p.input + Double(output) * p.output + Double(cacheRead) * read
            + Double(cacheWrite5m) * p.input * 1.25 + Double(cacheWrite1h) * p.input * 2) / 1e6
    }

    /// What the cached-read tokens would have cost extra at the full input rate.
    var cacheSavings: Double {
        let p = price
        return Double(cacheRead) * (p.input - (p.cacheRead ?? p.input * 0.1)) / 1e6
    }
}

struct CodeSession: Identifiable {
    let id: String
    var title: String
    var project: String
    var start: Date
    var end: Date
    var messages = 0
    var tokens = 0
    var cost = 0.0
    var models: Set<String> = []

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct DayStat {
    var cost = 0.0
    var tokens = 0
    var messages = 0
}

struct CodeStats {
    var sessions: [CodeSession] = []
    var days: [Date: DayStat] = [:]
    /// Same totals bucketed by the start of each local hour, for time-of-day views.
    var hours: [Date: DayStat] = [:]
    var byModel: [(name: String, cost: Double, tokens: Int)] = []
    var byProject: [(name: String, cost: Double, tokens: Int)] = []
    var hourHistogram = [Int](repeating: 0, count: 24)
    var cacheSavings = 0.0
    var cacheReadTokens = 0
    var inputSideTokens = 0
    var unknownModels: Set<String> = []

    static let empty = CodeStats()

    var isEmpty: Bool { sessions.isEmpty }

    func total(lastDays: Int?) -> DayStat {
        let cal = Calendar.current
        let cutoff = lastDays.flatMap { cal.date(byAdding: .day, value: -($0 - 1), to: cal.startOfDay(for: Date())) }
        var out = DayStat()
        for (day, s) in days where cutoff == nil || day >= cutoff! {
            out.cost += s.cost
            out.tokens += s.tokens
            out.messages += s.messages
        }
        return out
    }

    func sessionCount(lastDays: Int?) -> Int {
        guard let lastDays else { return sessions.count }
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(lastDays - 1), to: cal.startOfDay(for: Date()))!
        return sessions.filter { $0.end >= cutoff }.count
    }
}

// MARK: - Scanner

/// Reads Claude Code's local session logs (`~/.claude/projects/**/*.jsonl`). Read-only.
actor LogScanner {
    private struct Raw {
        let key: String
        let entry: CodeEntry
    }

    private struct FileResult {
        let mtime: Date
        let size: Int
        let entries: [Raw]
        let titles: [String: (rank: Int, text: String)]
    }

    private var cache: [String: FileResult] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let needles: [Data] = ["\"usage\"", "\"customTitle\"", "\"agentName\"", "\"lastPrompt\""]
        .map { Data($0.utf8) }

    func scan() -> CodeStats {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects"),
        ]

        var seen = Set<String>()
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = v.contentModificationDate, let size = v.fileSize else { continue }
                seen.insert(url.path)
                if let c = cache[url.path], c.mtime == mtime, c.size == size { continue }
                cache[url.path] = parse(url, mtime: mtime, size: size)
            }
        }
        for path in cache.keys where !seen.contains(path) { cache[path] = nil }
        return aggregate()
    }

    private func parse(_ url: URL, mtime: Date, size: Int) -> FileResult {
        var entries: [Raw] = []
        var titles: [String: (rank: Int, text: String)] = [:]
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return FileResult(mtime: mtime, size: size, entries: [], titles: [:])
        }
        for line in data.split(separator: 0x0A) {
            guard Self.needles.contains(where: { line.range(of: $0) != nil }),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let sid = obj["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent

            func title(_ field: String, rank: Int) {
                guard let t = obj[field] as? String, !t.isEmpty else { return }
                // Later, higher-ranked titles win; "lastPrompt" keeps the latest prompt.
                if (titles[sid]?.rank ?? -1) <= rank { titles[sid] = (rank, t) }
            }

            switch type {
            case "custom-title": title("customTitle", rank: 3)
            case "agent-name": title("agentName", rank: 2)
            case "last-prompt": title("lastPrompt", rank: 1)
            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let model = msg["model"] as? String, model.hasPrefix("claude"),
                      let ts = (obj["timestamp"] as? String).flatMap({ iso.date(from: $0) }) else { continue }
                func n(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
                var w5 = 0, w1 = 0
                if let cc = usage["cache_creation"] as? [String: Any] {
                    w5 = n(cc, "ephemeral_5m_input_tokens")
                    w1 = n(cc, "ephemeral_1h_input_tokens")
                } else {
                    w5 = n(usage, "cache_creation_input_tokens")
                }
                let entry = CodeEntry(
                    sessionId: sid, timestamp: ts, model: model, cwd: obj["cwd"] as? String ?? "",
                    input: n(usage, "input_tokens"), output: n(usage, "output_tokens"),
                    cacheRead: n(usage, "cache_read_input_tokens"), cacheWrite5m: w5, cacheWrite1h: w1)
                // Streaming writes the same message several times; the id pair identifies it.
                let key = "\(msg["id"] as? String ?? UUID().uuidString)|\(obj["requestId"] as? String ?? "")"
                entries.append(Raw(key: key, entry: entry))
            default: break
            }
        }
        return FileResult(mtime: mtime, size: size, entries: entries, titles: titles)
    }

    private func aggregate() -> CodeStats {
        // Keep the last-written copy of each message (it carries the final output token count).
        var unique: [String: CodeEntry] = [:]
        var titles: [String: (rank: Int, text: String)] = [:]
        for file in cache.values {
            for raw in file.entries {
                if let old = unique[raw.key], old.output > raw.entry.output { continue }
                unique[raw.key] = raw.entry
            }
            for (sid, t) in file.titles where (titles[sid]?.rank ?? -1) <= t.rank { titles[sid] = t }
        }

        let cal = Calendar.current
        var stats = CodeStats()
        var sessions: [String: CodeSession] = [:]
        var models: [String: (Double, Int)] = [:]
        var projects: [String: (Double, Int)] = [:]

        for e in unique.values where e.tokens > 0 {
            let cost = e.cost
            let project = e.cwd.isEmpty ? "Unknown" : URL(fileURLWithPath: e.cwd).lastPathComponent
            if Pricing.price(for: e.model) == nil { stats.unknownModels.insert(e.model) }

            let day = cal.startOfDay(for: e.timestamp)
            var d = stats.days[day] ?? DayStat()
            d.cost += cost
            d.tokens += e.tokens
            d.messages += 1
            stats.days[day] = d
            let hour = cal.dateInterval(of: .hour, for: e.timestamp)?.start ?? day
            var h = stats.hours[hour] ?? DayStat()
            h.cost += cost
            h.tokens += e.tokens
            h.messages += 1
            stats.hours[hour] = h
            stats.hourHistogram[cal.component(.hour, from: e.timestamp)] += 1
            stats.cacheSavings += e.cacheSavings
            stats.cacheReadTokens += e.cacheRead
            stats.inputSideTokens += e.input + e.cacheRead + e.cacheWrite5m + e.cacheWrite1h

            var m = models[e.model] ?? (0, 0)
            m.0 += cost
            m.1 += e.tokens
            models[e.model] = m
            var p = projects[project] ?? (0, 0)
            p.0 += cost
            p.1 += e.tokens
            projects[project] = p

            var s = sessions[e.sessionId] ?? CodeSession(
                id: e.sessionId, title: "", project: project, start: e.timestamp, end: e.timestamp)
            s.start = min(s.start, e.timestamp)
            s.end = max(s.end, e.timestamp)
            s.messages += 1
            s.tokens += e.tokens
            s.cost += cost
            s.models.insert(e.model)
            sessions[e.sessionId] = s
        }

        stats.sessions = sessions.values.map { s in
            var s = s
            let t = titles[s.id]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            s.title = t.isEmpty ? s.project : String(t.prefix(80))
            return s
        }.sorted { $0.end > $1.end }
        stats.byModel = models.map { (name: $0.key, cost: $0.value.0, tokens: $0.value.1) }.sorted { $0.cost > $1.cost }
        stats.byProject = projects.map { (name: $0.key, cost: $0.value.0, tokens: $0.value.1) }.sorted { $0.cost > $1.cost }
        return stats
    }
}
