import AppKit
import Charts
import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var model = AppModel()

    init() {
        if let dir = DevSnapshot.directory {
            Task { @MainActor in
                await DevSnapshot.run(into: dir)
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.needle")
            if let text = model.menuBarText { Text(text) }
        }
    }
}

// MARK: - Shell

enum Tab: String, CaseIterable, Identifiable {
    case usage = "Usage", sessions = "Sessions", activity = "Activity", insights = "Insights", code = "Code"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .usage: return "gauge.with.needle"
        case .sessions: return "clock.arrow.circlepath"
        case .activity: return "square.grid.3x3.fill"
        case .insights: return "chart.line.uptrend.xyaxis"
        case .code: return "terminal.fill"
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab
    @State private var showSettings: Bool

    private let height: CGFloat

    init(initialTab: Tab = .usage, showSettings: Bool = false, height: CGFloat = 600) {
        self.height = height
        _tab = State(initialValue: initialTab)
        _showSettings = State(initialValue: showSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSettings {
                ScrollView { SettingsView().padding(14) }
            } else {
                tabBar
                ScrollView {
                    Group {
                        switch tab {
                        case .usage: UsageTab()
                        case .sessions: SessionsTab()
                        case .activity: ActivityTab()
                        case .insights: InsightsTab()
                        case .code: CodeTab()
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 440, height: height)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showSettings {
                Text("Settings").font(.headline)
            } else if let acct = model.selected {
                Menu {
                    ForEach(model.accounts) { a in
                        Button(a.displayName) { model.selectedID = a.id }
                    }
                    Divider()
                    Button("Add account…") { model.addAccount() }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.palette[model.color(for: acct.id) % Theme.palette.count])
                            .frame(width: 8, height: 8)
                        Text(acct.displayName).font(.headline)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text("Claude Usage").font(.headline)
            }
            Spacer()
            Button {
                Task { await model.refreshAll() }
            } label: {
                if model.refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh now")
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
            }
            .help(showSettings ? "Close settings" : "Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 13))
                        Text(t.rawValue).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(tab == t ? Theme.accent : Color.secondary)
                    .background(tab == t ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyNote: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct UsageBar: View {
    let percent: Double
    var marker: Double? = nil      // 0...1, where "on pace" would be

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Theme.level(percent))
                    .frame(width: max(4, geo.size.width * min(percent, 100) / 100))
                if let marker {
                    Rectangle().fill(Color.primary.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: geo.size.width * min(max(marker, 0), 1) - 1)
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Usage

struct UsageTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let acct = model.selected {
                if let err = model.errors[acct.id] {
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(err.description).font(.subheadline.weight(.semibold))
                                Text("Sign in to claude.ai to load this account's limits.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sign in") { model.signIn(acct.id) }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                        }
                    }
                }
                if let u = model.usage[acct.id] {
                    ForEach(u.windows) { LimitCard(window: $0) }
                    SessionChart(accountID: acct.id)
                    Text("Updated \(u.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                } else if model.errors[acct.id] == nil {
                    HStack { Spacer(); ProgressView("Loading limits…"); Spacer() }.padding(.vertical, 30)
                }
                OtherAccounts(currentID: acct.id)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Track your Claude limits").font(.title3.weight(.semibold))
                        Text("Sign in with your Claude account to see your session and weekly limits live in the menu bar. You sign in on claude.ai itself — this app never sees your password.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Sign in to Claude") { model.addAccount() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
        }
    }
}

struct LimitCard: View {
    let window: LimitWindow

    /// Fraction of the window already elapsed, when its length is known.
    private var elapsed: Double? {
        guard let len = window.length, let reset = window.resetsAt else { return nil }
        let e = 1 - reset.timeIntervalSinceNow / len
        return (e > 0 && e <= 1) ? e : nil
    }

    private var projected: Double? {
        guard let e = elapsed, e > 0.08 else { return nil }
        return window.utilization / e
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(window.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(window.utilization.rounded()))%")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.level(window.utilization))
                }
                UsageBar(percent: window.utilization, marker: elapsed)
                HStack {
                    Text(Fmt.resetText(window.resetsAt))
                    Spacer()
                    if let p = projected {
                        Text(p > 100 ? "On pace to hit the limit" : "On pace for \(Int(p.rounded()))%")
                            .foregroundStyle(p > 100 ? Color.orange : Color.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct SessionChart: View {
    @EnvironmentObject var model: AppModel
    let accountID: UUID

    var body: some View {
        let cutoff = Date().addingTimeInterval(-86400)
        let points = model.snapshots
            .filter { $0.acct == accountID && $0.t > cutoff }
            .compactMap { s in s.w["five_hour"].map { (t: s.t, v: $0) } }
        if points.count >= 2 {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session usage · last 24 hours").font(.subheadline.weight(.semibold))
                    Chart {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                            AreaMark(x: .value("Time", p.t), y: .value("Used", p.v))
                                .interpolationMethod(.stepEnd)
                                .foregroundStyle(Theme.accent.opacity(0.18))
                            LineMark(x: .value("Time", p.t), y: .value("Used", p.v))
                                .interpolationMethod(.stepEnd)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .frame(height: 90)
                }
            }
        }
    }
}

struct OtherAccounts: View {
    @EnvironmentObject var model: AppModel
    let currentID: UUID

    var body: some View {
        let others = model.accounts.filter { $0.id != currentID }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Other accounts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(others) { a in
                    Button { model.selectedID = a.id } label: {
                        Card {
                            HStack(spacing: 8) {
                                Circle().fill(Theme.palette[model.color(for: a.id) % Theme.palette.count])
                                    .frame(width: 8, height: 8)
                                Text(a.displayName).font(.callout).lineLimit(1)
                                Spacer()
                                if let u = model.usage[a.id] {
                                    if let s = u.window("five_hour") { pill("Session", s.utilization) }
                                    if let w = u.window("seven_day") { pill("Week", w.utilization) }
                                } else {
                                    Text(model.errors[a.id]?.description ?? "Loading…")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pill(_ label: String, _ pct: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text("\(Int(pct.rounded()))%").fontWeight(.semibold).foregroundStyle(Theme.level(pct))
        }
        .font(.caption)
    }
}

// MARK: - Sessions

struct SessionsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var showCode = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $showCode) {
                Text("Limit windows").tag(false)
                Text("Claude Code").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if showCode { codeList } else { limitList }
        }
    }

    @ViewBuilder private var limitList: some View {
        let sessions = model.selected.map { model.limitSessions(for: $0.id) } ?? []
        if sessions.isEmpty {
            EmptyNote(icon: "clock.arrow.circlepath",
                      text: "No session windows recorded yet.\nEach 5-hour window is logged here while the app is running.")
        } else {
            LazyVStack(spacing: 6) {
                ForEach(sessions) { s in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(Fmt.dayTime(s.start)) – \(s.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.callout)
                                if s.end > Date() {
                                    Text("ACTIVE").font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                                }
                                Spacer()
                                Text("\(Int(s.peak.rounded()))%").font(.callout.weight(.semibold))
                                    .foregroundStyle(Theme.level(s.peak))
                            }
                            UsageBar(percent: s.peak)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var codeList: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let sessions = model.code.sessions.filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.project.lowercased().contains(q)
        }
        TextField("Search sessions", text: $search).textFieldStyle(.roundedBorder)
        if sessions.isEmpty {
            EmptyNote(icon: "terminal", text: model.code.isEmpty ? "No Claude Code sessions found on this Mac." : "No sessions match.")
        } else {
            LazyVStack(spacing: 6) {
                ForEach(sessions.prefix(300)) { s in
                    Card {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text("\(s.project) · \(Fmt.dayTime(s.start)) · \(Fmt.duration(s.duration))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(Fmt.money(s.cost)).font(.callout.weight(.semibold))
                                Text("\(Fmt.tokens(s.tokens)) tok").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Insights

struct InsightsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let acct = model.selected
        let insights = InsightsEngine.build(
            code: model.code,
            usage: acct.flatMap { model.usage[$0.id] },
            sessions: acct.map { model.limitSessions(for: $0.id) } ?? [])
        if insights.isEmpty {
            EmptyNote(icon: "chart.line.uptrend.xyaxis", text: "Insights appear once there's some usage to analyze.")
        } else {
            VStack(spacing: 8) {
                ForEach(insights) { i in
                    Card {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: i.icon)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 30, height: 30)
                                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(i.title).font(.callout.weight(.semibold))
                                Text(i.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Claude Code stats

struct CodeTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let code = model.code
        if code.isEmpty {
            EmptyNote(icon: "terminal", text: "No Claude Code sessions found on this Mac.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        period("Today", 1)
                        period("Last 7 days", 7)
                    }
                    GridRow {
                        period("Last 30 days", 30)
                        period("All time", nil)
                    }
                }
                dailyChart
                breakdown("Models", code.byModel)
                breakdown("Projects", Array(code.byProject.prefix(6)))
                Text("Costs are API-equivalent estimates at list prices, from Claude Code's logs on this Mac. A subscription isn't billed per token."
                     + (code.unknownModels.isEmpty ? "" : " Unrecognized models priced at Sonnet rates: \(code.unknownModels.sorted().joined(separator: ", "))."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func period(_ label: String, _ days: Int?) -> some View {
        let t = model.code.total(lastDays: days)
        return Card {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(Fmt.money(t.cost)).font(.system(size: 20, weight: .bold, design: .rounded))
                Text("\(Fmt.tokens(t.tokens)) tokens · \(model.code.sessionCount(lastDays: days)) sessions")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dailyChart: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0..<14).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Daily cost · last 14 days").font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(days, id: \.self) { d in
                        BarMark(x: .value("Day", d, unit: .day), y: .value("Cost", model.code.days[d]?.cost ?? 0))
                            .foregroundStyle(Theme.accent)
                            .cornerRadius(2)
                    }
                }
                .frame(height: 100)
            }
        }
    }

    private func breakdown(_ title: String, _ rows: [(name: String, cost: Double, tokens: Int)]) -> some View {
        let top = rows.map(\.cost).max() ?? 0
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(rows, id: \.name) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(Fmt.money(row.cost)) · \(Fmt.tokens(row.tokens))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            Capsule().fill(Theme.accent.opacity(0.7))
                                .frame(width: max(3, geo.size.width * (top > 0 ? row.cost / top : 0)))
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accounts").font(.subheadline.weight(.semibold))
            ForEach($model.accounts) { $acct in
                Card {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.palette[model.color(for: acct.id) % Theme.palette.count])
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(acct.email ?? "Account name", text: $acct.name)
                                .textFieldStyle(.plain).font(.callout)
                            Text(status(acct)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Sign in again") { model.signIn(acct.id) }
                            Button("Sign out") { Task { await model.signOut(acct.id) } }
                            Divider()
                            Button("Remove account", role: .destructive) { Task { await model.removeAccount(acct.id) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            Button {
                model.addAccount()
            } label: {
                Label("Add account", systemImage: "plus")
            }

            Divider()

            Text("Preferences").font(.subheadline.weight(.semibold))
            Picker("Menu bar shows", selection: $model.menuBarMode) {
                ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Refresh every", selection: $model.refreshMinutes) {
                ForEach([1, 2, 5, 15], id: \.self) { Text("\($0) min").tag($0) }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))

            Divider()

            AboutSection()

            Divider()

            HStack {
                Button("Copy raw usage response") {
                    guard let raw = model.selected.flatMap({ model.usage[$0.id]?.raw }) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                }
                .disabled(model.selected.flatMap { model.usage[$0.id] } == nil)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private func status(_ a: Account) -> String {
        if let e = model.errors[a.id] { return e.description }
        if model.usage[a.id] != nil { return "Signed in" }
        return a.orgId == nil ? "Not signed in" : "Loading…"
    }
}

struct AboutSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("About").font(.subheadline.weight(.semibold))
                Text("Version \(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Claude Usage is free and open source. It's an unofficial tool, not affiliated with or endorsed by Anthropic. Everything stays on your Mac: no analytics, no servers of its own.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tip = AppInfo.tipJarURL {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enjoying the app?").font(.callout.weight(.semibold))
                            Text("A tip helps keep it maintained. Entirely optional.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("Leave a tip", destination: tip)
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
            if let source = AppInfo.sourceURL {
                HStack(spacing: 14) {
                    Link(destination: source) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: source.appending(path: "issues")) { Label("Report an issue", systemImage: "exclamationmark.bubble") }
                }
                .font(.caption)
            }
        }
    }
}
