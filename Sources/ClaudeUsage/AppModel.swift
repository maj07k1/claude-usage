import AppKit
import Foundation
import ServiceManagement
import WebKit

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = [] { didSet { saveAccounts() } }
    @Published var selectedID: UUID? {
        didSet { if persist { defaults.set(selectedID?.uuidString, forKey: "selectedAccount") } }
    }
    @Published var usage: [UUID: AccountUsage] = [:]
    @Published var errors: [UUID: WebError] = [:]
    @Published var refreshing = false
    @Published var snapshots: [Snapshot] = []
    @Published var code = CodeStats.empty
    @Published var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: "refreshMinutes")
            scheduleTimer()
        }
    }

    private let persist: Bool
    private let defaults = UserDefaults.standard
    private let scanner = LogScanner()
    private var sessions: [UUID: WebSession] = [:]
    private var loginTasks: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var lastRefresh = Date.distantPast

    /// `persist: false` gives an isolated model (no saved state, no timers, no network) for DevSnapshot.
    init(persist: Bool = true) {
        self.persist = persist
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .session
        let minutes = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = minutes > 0 ? minutes : 5
        guard persist else { return }
        if let data = defaults.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
        selectedID = defaults.string(forKey: "selectedAccount").flatMap(UUID.init)
        loadHistory()
        scheduleTimer()
        // Opening the menu bar panel refreshes if the data is more than a minute old.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastRefresh) > 60 else { return }
                await self.refreshAll()
            }
        }
        Task { await refreshAll() }
    }

    // MARK: Accounts

    var selected: Account? { accounts.first { $0.id == selectedID } ?? accounts.first }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func color(for id: UUID) -> Int { accounts.firstIndex { $0.id == id } ?? 0 }

    private func saveAccounts() {
        guard persist else { return }
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: "accounts") }
    }

    private func session(for id: UUID) -> WebSession {
        if let s = sessions[id] { return s }
        let s = WebSession(accountID: id)
        sessions[id] = s
        return s
    }

    func addAccount() {
        let a = Account()
        accounts.append(a)
        selectedID = a.id
        signIn(a.id)
    }

    /// Opens claude.ai's own login page in a window and waits for the session to become valid.
    func signIn(_ id: UUID) {
        let s = session(for: id)
        s.showLogin()
        loginTasks[id]?.cancel()
        loginTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled, s.isLoginVisible {
                guard let self else { return }
                if (try? await self.discover(id)) != nil {
                    s.closeLogin()
                    await s.park()
                    await self.refresh(id)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func signOut(_ id: UUID) async {
        loginTasks[id]?.cancel()
        let s = session(for: id)
        s.closeLogin()
        await s.webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        sessions[id] = nil
        usage[id] = nil
        errors[id] = .notSignedIn
        if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i].orgId = nil }
    }

    func removeAccount(_ id: UUID) async {
        await signOut(id)
        accounts.removeAll { $0.id == id }
        errors[id] = nil
        snapshots.removeAll { $0.acct == id }
        saveHistory()
        if selectedID == id { selectedID = accounts.first?.id }
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    // MARK: Fetching

    private func discover(_ id: UUID) async throws {
        let s = session(for: id)
        let body = try await s.get("/api/organizations")
        guard let orgs = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]],
              !orgs.isEmpty else { throw WebError.badResponse }
        // Prefer the org that carries the chat subscription over API-only orgs.
        let pick = orgs.first { org in
            let caps = org["capabilities"] as? [String] ?? []
            return caps.contains { $0 == "chat" || $0.hasPrefix("claude_") }
        } ?? orgs[0]
        guard let org = pick["uuid"] as? String else { throw WebError.badResponse }

        var email: String?
        if let acct = try? await s.get("/api/account"),
           let obj = try? JSONSerialization.jsonObject(with: Data(acct.utf8)) as? [String: Any] {
            email = obj["email_address"] as? String
        }
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].orgId = org
        if let email { accounts[i].email = email }
    }

    func refresh(_ id: UUID) async {
        let s = session(for: id)
        do {
            if account(id)?.orgId == nil { try await discover(id) }
            guard let org = account(id)?.orgId else { return }
            let body = try await s.get("/api/organizations/\(org)/usage")
            let windows = UsageParser.parse(body)
            usage[id] = AccountUsage(windows: windows, fetchedAt: Date(), raw: body)
            errors[id] = windows.isEmpty ? .badResponse : nil
            record(id, windows)
        } catch let e as WebError {
            if case .busy = e { return }
            if case .http(404) = e, let i = accounts.firstIndex(where: { $0.id == id }) {
                accounts[i].orgId = nil      // stale org; rediscover next time
            }
            errors[id] = e
        } catch {
            NSLog("ClaudeUsage: refresh failed: %@", String(describing: error))
            errors[id] = .badResponse
        }
    }

    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        lastRefresh = Date()
        defer { refreshing = false }
        for a in accounts { await refresh(a.id) }
        await scanCode()
    }

    func scanCode() async {
        code = await scanner.scan()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        timer?.tolerance = 10      // lets macOS coalesce wake-ups to save power
    }

    // MARK: Menu bar

    var menuBarText: String? {
        guard let a = selected else { return nil }
        guard let u = usage[a.id] else { return errors[a.id] == nil ? nil : "!" }
        func pct(_ key: String) -> String? { u.window(key).map { "\(Int($0.utilization.rounded()))%" } }
        switch menuBarMode {
        case .session: return pct("five_hour")
        case .weekly: return pct("seven_day")
        case .both:
            let parts = [pct("five_hour"), pct("seven_day")].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .iconOnly: return nil
        }
    }

    // MARK: History

    private var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func loadHistory() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: historyURL) else { return }
        do {
            snapshots = try dec.decode([Snapshot].self, from: data)
        } catch {
            // Keep the unreadable file instead of silently overwriting it on the next save.
            let backup = historyURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: historyURL, to: backup)
            NSLog("ClaudeUsage: history unreadable, moved to %@: %@", backup.lastPathComponent, String(describing: error))
        }
    }

    private func saveHistory() {
        guard persist else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(snapshots) { try? data.write(to: historyURL, options: .atomic) }
    }

    private func record(_ id: UUID, _ windows: [LimitWindow]) {
        guard !windows.isEmpty else { return }
        let w = Dictionary(windows.map { ($0.key, $0.utilization) }, uniquingKeysWith: { a, _ in a })
        let r = Dictionary(windows.compactMap { win in win.resetsAt.map { (win.key, $0) } }, uniquingKeysWith: { a, _ in a })
        // Unchanged readings are only kept every 30 minutes so the file stays small.
        if let last = snapshots.last(where: { $0.acct == id }), last.w == w,
           Date().timeIntervalSince(last.t) < 1800 { return }
        snapshots.append(Snapshot(t: Date(), acct: id, w: w, r: r))
        let cutoff = Date().addingTimeInterval(-200 * 86400)
        snapshots.removeAll { $0.t < cutoff }
        saveHistory()
    }

    /// 5-hour limit windows seen for an account, newest first.
    func limitSessions(for id: UUID) -> [LimitSession] {
        var peaks: [Date: Double] = [:]
        for s in snapshots where s.acct == id {
            guard let reset = s.r["five_hour"], let u = s.w["five_hour"] else { continue }
            let key = Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded() * 60)
            peaks[key] = max(peaks[key] ?? 0, u)
        }
        return peaks.filter { $0.value > 0 }
            .map { LimitSession(id: "\($0.key.timeIntervalSince1970)", start: $0.key.addingTimeInterval(-5 * 3600), end: $0.key, peak: $0.value) }
            .sorted { $0.end > $1.end }
    }

    /// Highest session utilization per day for an account.
    func dailyPeaks(for id: UUID) -> [Date: Double] {
        let cal = Calendar.current
        var out: [Date: Double] = [:]
        for s in snapshots where s.acct == id {
            guard let u = s.w["five_hour"] else { continue }
            let day = cal.startOfDay(for: s.t)
            out[day] = max(out[day] ?? 0, u)
        }
        return out
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ClaudeUsage: launch at login failed: %@", String(describing: error))
        }
        objectWillChange.send()
    }
}

// MARK: - Insights

struct Insight: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

enum InsightsEngine {
    /// Current and longest runs of consecutive days. `days` must be start-of-day dates in `cal`.
    static func streaks(_ days: Set<Date>, now: Date = Date(), calendar cal: Calendar = .current) -> (current: Int, longest: Int) {
        var longest = 0
        var run = 0
        var prev: Date?
        for d in days.sorted() {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            longest = max(longest, run)
            prev = d
        }
        // A streak is still alive if the most recent active day is today or yesterday.
        var current = 0
        var cursor = cal.startOfDay(for: now)
        if !days.contains(cursor), let yesterday = cal.date(byAdding: .day, value: -1, to: cursor) { cursor = yesterday }
        while days.contains(cursor), let prev = cal.date(byAdding: .day, value: -1, to: cursor) {
            current += 1
            cursor = prev
        }
        return (current, longest)
    }

    static func build(code: CodeStats, usage: AccountUsage?, sessions: [LimitSession]) -> [Insight] {
        var out: [Insight] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Live limits
        if let week = usage?.window("seven_day"), let reset = week.resetsAt, let len = week.length {
            let elapsed = 1 - reset.timeIntervalSinceNow / len
            if elapsed > 0.08, elapsed <= 1 {
                let projected = week.utilization / elapsed
                let left = Fmt.duration(reset.timeIntervalSinceNow)
                out.append(Insight(
                    icon: projected > 100 ? "exclamationmark.triangle.fill" : "speedometer",
                    title: projected > 100 ? "On pace to hit your weekly limit" : "Weekly pace looks fine",
                    detail: "You've used \(Int(week.utilization.rounded()))% with \(left) left. At this rate you'd reach about \(Int(projected.rounded()))% by reset."))
            }
        }
        let recent = sessions.filter { $0.end > Date().addingTimeInterval(-7 * 86400) }
        if !recent.isEmpty {
            let hits = recent.filter { $0.peak >= 99 }.count
            let avg = recent.map(\.peak).reduce(0, +) / Double(recent.count)
            out.append(Insight(
                icon: "timer",
                title: hits > 0 ? "You hit the session limit \(hits)× this week" : "No session limits hit this week",
                detail: "\(recent.count) session windows recorded in the last 7 days, peaking at \(Int(avg.rounded()))% on average."))
        }

        guard !code.isEmpty else { return out }

        // Claude Code
        let all = code.total(lastDays: nil)
        let active = Set(code.days.filter { $0.value.messages > 0 }.keys)
        let s = streaks(active)
        out.append(Insight(
            icon: "flame.fill", title: "\(s.current)-day streak",
            detail: "Your longest run of consecutive active days is \(s.longest). You've been active on \(active.count) days in total."))

        let last7 = code.total(lastDays: 7).cost
        let prev7 = code.total(lastDays: 14).cost - last7
        if prev7 > 0 {
            let change = (last7 / prev7 - 1) * 100
            out.append(Insight(
                icon: change >= 0 ? "arrow.up.right" : "arrow.down.right",
                title: "Usage is \(change >= 0 ? "up" : "down") \(Int(abs(change).rounded()))% week over week",
                detail: "\(Fmt.money(last7)) in the last 7 days versus \(Fmt.money(prev7)) the week before."))
        }

        if let comps = Optional(cal.dateComponents([.year, .month], from: today)),
           let monthStart = cal.date(from: comps),
           let range = cal.range(of: .day, in: .month, for: today) {
            let soFar = code.days.filter { $0.key >= monthStart }.map(\.value.cost).reduce(0, +)
            let day = cal.component(.day, from: today)
            if soFar > 0 {
                out.append(Insight(
                    icon: "chart.line.uptrend.xyaxis", title: "Projected \(Fmt.money(soFar / Double(day) * Double(range.count))) this month",
                    detail: "\(Fmt.money(soFar)) of API-equivalent usage so far, \(day) days into the month."))
            }
        }

        if let busiest = code.days.max(by: { $0.value.cost < $1.value.cost }) {
            out.append(Insight(
                icon: "calendar", title: "Busiest day: \(Fmt.shortDate(busiest.key))",
                detail: "\(Fmt.money(busiest.value.cost)) and \(Fmt.tokens(busiest.value.tokens)) tokens across \(busiest.value.messages) responses."))
        }

        if let peak = code.hourHistogram.enumerated().max(by: { $0.element < $1.element }), peak.element > 0,
           let date = cal.date(bySettingHour: peak.offset, minute: 0, second: 0, of: today) {
            let total = code.hourHistogram.reduce(0, +)
            out.append(Insight(
                icon: "clock", title: "Most active around \(date.formatted(.dateTime.hour()))",
                detail: "\(Int((Double(peak.element) / Double(total) * 100).rounded()))% of your Claude Code responses land in that hour."))
        }

        if let top = code.byModel.first, all.cost > 0 {
            out.append(Insight(
                icon: "cpu", title: "\(top.name) is your main model",
                detail: "It accounts for \(Int((top.cost / all.cost * 100).rounded()))% of cost (\(Fmt.money(top.cost)), \(Fmt.tokens(top.tokens)) tokens)."))
        }

        if let top = code.byProject.first, all.cost > 0, code.byProject.count > 1 {
            out.append(Insight(
                icon: "folder", title: "Top project: \(top.name)",
                detail: "\(Int((top.cost / all.cost * 100).rounded()))% of cost across \(code.byProject.count) projects."))
        }

        if code.inputSideTokens > 0 {
            let rate = Double(code.cacheReadTokens) / Double(code.inputSideTokens) * 100
            out.append(Insight(
                icon: "bolt.fill", title: "\(Int(rate.rounded()))% of input came from cache",
                detail: "Prompt caching saved roughly \(Fmt.money(code.cacheSavings)) compared with paying the full input rate."))
        }

        if let longest = code.sessions.max(by: { $0.duration < $1.duration }), longest.duration > 60 {
            out.append(Insight(
                icon: "hourglass", title: "Longest session: \(Fmt.duration(longest.duration))",
                detail: "“\(longest.title)” — \(Fmt.money(longest.cost)), \(Fmt.tokens(longest.tokens)) tokens."))
        }
        return out
    }
}
