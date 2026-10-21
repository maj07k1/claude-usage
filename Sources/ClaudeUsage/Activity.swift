import SwiftUI

// MARK: - Metric & range

enum GridMetric: String, CaseIterable, Identifiable {
    case cost = "Cost", tokens = "Tokens", messages = "Responses", peak = "Limit peak"
    var id: String { rawValue }

    /// What one Claude Code bucket contributes. `nil` for the limit metric, which comes from snapshots.
    func value(_ s: DayStat) -> Double? {
        switch self {
        case .cost: return s.cost
        case .tokens: return Double(s.tokens)
        case .messages: return Double(s.messages)
        case .peak: return nil
        }
    }

    /// Value with its unit, for sentences and tooltips.
    func format(_ v: Double) -> String {
        switch self {
        case .cost: return Fmt.money(v)
        case .tokens: return "\(Fmt.tokens(Int(v))) tokens"
        case .messages: return Int(v) == 1 ? "1 response" : "\(Fmt.count(Int(v))) responses"
        case .peak: return "\(Int(v.rounded()))% of session limit"
        }
    }

    /// Compact value without a unit, for stat tiles.
    func short(_ v: Double) -> String {
        switch self {
        case .cost: return Fmt.money(v)
        case .tokens: return Fmt.tokens(Int(v))
        case .messages: return Fmt.count(Int(v))
        case .peak: return "\(Int(v.rounded()))%"
        }
    }
}

enum ActivityRange: Int, CaseIterable, Identifiable {
    case quarter = 13, half = 26, year = 52
    var id: Int { rawValue }
    var weeks: Int { rawValue }
    var label: String {
        switch self {
        case .quarter: return "3M"
        case .half: return "6M"
        case .year: return "1Y"
        }
    }
    var title: String {
        switch self {
        case .quarter: return "Last 3 months"
        case .half: return "Last 6 months"
        case .year: return "Last 12 months"
        }
    }
}

// MARK: - Shading

/// Maps a value to one of five shades (0 = no activity, 4 = most).
///
/// By default a value is ranked among the other active days, so one huge day can't wash out the
/// rest of the grid and a single active day still shows at full strength. `bounds` switches to fixed
/// cut-offs instead (used for limit percentages, which already have a natural scale).
struct HeatScale {
    private let sorted: [Double]
    private let bounds: [Double]?

    init<S: Sequence>(values: S) where S.Element == Double {
        sorted = values.filter { $0 > 0 }.sorted()
        bounds = nil
    }

    /// Lower bounds for levels 2, 3 and 4.
    init(bounds: [Double]) {
        sorted = []
        self.bounds = bounds
    }

    func level(_ v: Double) -> Int {
        guard v > 0 else { return 0 }
        if let bounds { return 1 + bounds.filter { v >= $0 }.count }
        guard !sorted.isEmpty else { return 4 }
        // Number of active values <= v (upper bound by binary search).
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= v { lo = mid + 1 } else { hi = mid }
        }
        return min(4, max(1, Int((4 * Double(lo) / Double(sorted.count)).rounded(.up))))
    }

    static func color(_ level: Int) -> Color {
        switch level {
        case ...0: return Color.primary.opacity(0.08)
        case 1: return Theme.accent.opacity(0.3)
        case 2: return Theme.accent.opacity(0.5)
        case 3: return Theme.accent.opacity(0.75)
        default: return Theme.accent
        }
    }
}

// MARK: - Stats

/// Everything the Activity tab shows for one metric and range. Pure, so it can be tested.
struct ActivityStats {
    let metric: GridMetric
    let weeks: Int
    let calendar: Calendar
    /// Start of today.
    let today: Date
    /// Top-left cell: the start of the week `weeks - 1` weeks before this one.
    let first: Date
    /// Days from `first` through today, inclusive.
    let dayCount: Int
    /// All recorded days with a positive value, keyed by start of day.
    let values: [Date: Double]
    let scale: HeatScale
    let activeDays: Int
    let total: Double
    /// Total over the `dayCount` days immediately before `first`.
    let previousTotal: Double
    let best: (date: Date, value: Double)?
    let streak: (current: Int, longest: Int)
    /// Days at or above 90% of the session limit (limit metric only).
    let nearLimitDays: Int

    init(metric: GridMetric, values: [Date: Double], weeks: Int, now: Date = Date(), calendar: Calendar = .current) {
        self.metric = metric
        self.weeks = weeks
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        let weekday = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -(weekday + (weeks - 1) * 7), to: today) ?? today
        let dayCount = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        let previousStart = calendar.date(byAdding: .day, value: -dayCount, to: first) ?? first
        self.today = today
        self.first = first
        self.dayCount = dayCount

        let positive = values.filter { $0.value > 0 }
        let inRange = positive.filter { $0.key >= first && $0.key <= today }
        self.values = positive
        scale = metric == .peak ? HeatScale(bounds: [25, 50, 75]) : HeatScale(values: inRange.values)
        activeDays = inRange.count
        total = inRange.values.reduce(0, +)
        previousTotal = positive.filter { $0.key >= previousStart && $0.key < first }.values.reduce(0, +)
        // Highest value; the most recent day wins a tie.
        best = inRange.max { ($0.value, $0.key) < ($1.value, $1.key) }.map { (date: $0.key, value: $0.value) }
        streak = InsightsEngine.streaks(Set(positive.keys), now: now, calendar: calendar)
        nearLimitDays = metric == .peak ? inRange.values.filter { $0 >= 90 }.count : 0
    }

    /// Mean over active days (for the limit metric, the mean daily peak).
    var average: Double { activeDays > 0 ? total / Double(activeDays) : 0 }

    /// Percent change against the previous period, when there is one to compare with.
    var change: Double? { previousTotal > 0 ? (total / previousTotal - 1) * 100 : nil }

    func value(on day: Date) -> Double { values[day] ?? 0 }

    func date(column: Int, row: Int) -> Date {
        calendar.date(byAdding: .day, value: column * 7 + row, to: first) ?? first
    }

    func cell(for day: Date) -> GridCell? {
        guard let n = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: day)).day,
              n >= 0, n < weeks * 7 else { return nil }
        return GridCell(column: n / 7, row: n % 7)
    }

    func contains(_ day: Date) -> Bool { day >= first && day <= today }
}

/// Claude Code activity folded onto a week: 7 weekday rows × 24 hour columns.
struct WeekHourStats {
    /// `[row][hour]`; row 0 is the calendar's first weekday.
    let cells: [[Double]]
    let scale: HeatScale
    let total: Double

    /// The limit metric has no hourly data, so it falls back to response counts.
    init(hours: [Date: DayStat], metric: GridMetric, from start: Date, calendar: Calendar = .current) {
        let m = metric == .peak ? GridMetric.messages : metric
        var cells = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for (hour, s) in hours where hour >= start {
            let row = (calendar.component(.weekday, from: hour) - calendar.firstWeekday + 7) % 7
            cells[row][calendar.component(.hour, from: hour)] += m.value(s) ?? 0
        }
        self.cells = cells
        scale = HeatScale(values: cells.joined())
        total = cells.joined().reduce(0, +)
    }

    var busiest: (cell: GridCell, value: Double)? {
        var out: (cell: GridCell, value: Double)?
        for (r, row) in cells.enumerated() {
            for (h, v) in row.enumerated() where v > (out?.value ?? 0) {
                out = (GridCell(column: h, row: r), v)
            }
        }
        return out
    }
}

// MARK: - Grid geometry

struct GridCell: Hashable {
    let column: Int
    let row: Int
}

/// Lays out a `columns × rows` grid of square cells in a given width, with room for labels on the
/// leading edge and above. Cells grow to fill the width up to `maxCell`, then the block is centered.
struct GridGeometry {
    let columns: Int
    let rows: Int
    let cell: CGFloat
    let gap: CGFloat
    /// Top-left of the first cell.
    let origin: CGPoint
    /// Where leading labels start.
    let labelX: CGFloat
    let height: CGFloat

    init(width: CGFloat, columns: Int, rows: Int, leading: CGFloat, top: CGFloat,
         maxCell: CGFloat, gapRatio: CGFloat = 0.25) {
        self.columns = columns
        self.rows = rows
        let units = CGFloat(columns) + CGFloat(columns - 1) * gapRatio
        cell = max(2, min(maxCell, (width - leading) / units))
        gap = cell * gapRatio
        labelX = max(0, (width - leading - cell * units) / 2)
        origin = CGPoint(x: labelX + leading, y: top)
        height = top + cell * (CGFloat(rows) + CGFloat(rows - 1) * gapRatio)
    }

    var step: CGFloat { cell + gap }

    func rect(_ c: GridCell) -> CGRect {
        CGRect(x: origin.x + CGFloat(c.column) * step, y: origin.y + CGFloat(c.row) * step, width: cell, height: cell)
    }

    /// The cell under a point; points in a gap snap to the nearest cell so hovering doesn't flicker.
    func hitTest(_ p: CGPoint) -> GridCell? {
        let c = Int(((p.x - origin.x + gap / 2) / step).rounded(.down))
        let r = Int(((p.y - origin.y + gap / 2) / step).rounded(.down))
        guard (0..<columns).contains(c), (0..<rows).contains(r) else { return nil }
        return GridCell(column: c, row: r)
    }
}

// MARK: - Tab

struct ActivityTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("activityMetric") private var metric: GridMetric = .cost
    @AppStorage("activityRange") private var range: ActivityRange = .half
    @State private var hovered: Date?
    @State private var selected: Date?

    var body: some View {
        let peaks = model.selected.map { model.dailyPeaks(for: $0.id) } ?? [:]
        let values = metric == .peak ? peaks : model.code.days.compactMapValues { metric.value($0) }
        let stats = ActivityStats(metric: metric, values: values, weeks: range.weeks)

        VStack(alignment: .leading, spacing: 12) {
            Picker("Metric", selection: $metric) {
                ForEach(GridMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let empty = emptyMessage(hasValues: !stats.values.isEmpty) {
                EmptyNote(icon: metric == .peak ? "gauge.with.needle" : "square.grid.3x3", text: empty)
            } else {
                heatmapCard(stats)
                dayDetail(stats, peaks: peaks)
                summary(stats)
                if !model.code.isEmpty {
                    WeekHourCard(stats: WeekHourStats(hours: model.code.hours, metric: metric, from: stats.first),
                                 metric: metric, range: range)
                }
                if metric == .peak {
                    Text("Limit peaks are recorded while the app is running, so gaps mean the app wasn't open — not that you didn't use Claude.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: metric) { hovered = nil }
        .onChange(of: range) { hovered = nil }
    }

    private func emptyMessage(hasValues: Bool) -> String? {
        guard !hasValues else { return nil }
        switch metric {
        case .peak:
            return model.selected == nil
                ? "Sign in to an account to track your daily limit peaks."
                : "No limit readings yet.\nDaily peaks are recorded while the app is running."
        default:
            return "No Claude Code activity found on this Mac yet.\nIt appears here as soon as you use Claude Code."
        }
    }

    // MARK: Heatmap

    private func heatmapCard(_ stats: ActivityStats) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(range.title).font(.subheadline.weight(.semibold))
                        Text(headline(stats)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(ActivityRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }

                HeatmapGrid(stats: stats, hovered: $hovered, selected: $selected)

                HStack(spacing: 4) {
                    Text(selected == nil ? "Hover or click a day for details" : "Click the day again to unpin it")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2).fill(HeatScale.color(level)).frame(width: 9, height: 9)
                    }
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
                .help(metric == .peak
                      ? "Shades step at 25%, 50% and 75% of the session limit."
                      : "Shades rank each day against your other active days in this range.")
            }
        }
    }

    private func headline(_ stats: ActivityStats) -> String {
        let n = stats.activeDays
        switch metric {
        case .peak:
            return n == 0 ? "No readings in this range" : (n == 1 ? "1 tracked day" : "\(n) tracked days")
        default:
            return n == 0 ? "No activity in this range"
                : "\(metric.format(stats.total)) across \(n == 1 ? "1 active day" : "\(n) active days")"
        }
    }

    // MARK: Day detail

    private func dayDetail(_ stats: ActivityStats, peaks: [Date: Double]) -> some View {
        let day = hovered ?? selected ?? stats.today
        let end = stats.calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let sessions = model.code.sessions
            .filter { $0.start < end && $0.end >= day }
            .sorted { $0.cost > $1.cost }
        return DayDetailCard(
            day: day, isToday: day == stats.today, isPinned: selected == day && hovered == nil,
            stat: model.code.days[day], peak: peaks[day], sessions: sessions, metric: metric,
            showsCode: !model.code.isEmpty,
            onUnpin: { selected = nil })
    }

    // MARK: Summary

    private func summary(_ stats: ActivityStats) -> some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                if metric == .peak {
                    tile("Avg peak", stats.activeDays > 0 ? metric.short(stats.average) : "—", "per tracked day")
                    tile("Near limit", "\(stats.nearLimitDays)", stats.nearLimitDays == 1 ? "day ≥ 90%" : "days ≥ 90%")
                    tile("Highest", stats.best.map { metric.short($0.value) } ?? "—",
                         stats.best.map { Fmt.shortDate($0.date) } ?? "no readings")
                    tile("Tracked", "\(stats.activeDays)", "of \(stats.dayCount) days")
                } else {
                    tile("Total", metric.short(stats.total), changeText(stats))
                        .help("Compared with the \(stats.dayCount) days before this range")
                    tile("Daily avg", stats.activeDays > 0 ? metric.short(stats.average) : "—", "per active day")
                    tile("Active", "\(stats.activeDays)", "of \(stats.dayCount) days")
                    tile("Streak", "\(stats.streak.current)d", "best \(stats.streak.longest)d")
                }
            }
        }
    }

    private func changeText(_ stats: ActivityStats) -> String {
        guard let c = stats.change else { return stats.total > 0 ? "new this period" : "—" }
        if abs(c) < 0.5 { return "same as before" }
        return "\(c > 0 ? "↑" : "↓") \(Int(abs(c).rounded()))% vs before"
    }

    private func tile(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Heatmap grid

struct HeatmapGrid: View {
    let stats: ActivityStats
    @Binding var hovered: Date?
    @Binding var selected: Date?
    @State private var width: CGFloat = 388

    private var geometry: GridGeometry {
        GridGeometry(width: width, columns: stats.weeks, rows: 7, leading: 24, top: 14, maxCell: 18)
    }

    var body: some View {
        let geo = geometry
        let focus = hovered ?? selected
        Canvas { ctx, _ in
            let cal = stats.calendar
            let label = { (s: String) in Text(s).font(.system(size: 9)).foregroundColor(.secondary) }

            // Weekday labels in the calendar's own order; every other row when cells are too small.
            for row in 0..<7 where geo.step >= 12 || row % 2 == 0 {
                let symbol = cal.shortWeekdaySymbols[(cal.firstWeekday - 1 + row) % 7]
                let r = geo.rect(GridCell(column: 0, row: row))
                ctx.draw(label(symbol), at: CGPoint(x: geo.labelX, y: r.midY), anchor: .leading)
            }

            // Month labels over the column holding each month's 1st. The first column gets its own
            // month too, unless that would crowd the next label.
            var months: [(column: Int, date: Date)] = (0..<stats.weeks).compactMap { column in
                (0..<7).map { stats.date(column: column, row: $0) }
                    .first { cal.component(.day, from: $0) == 1 }
                    .map { (column, $0) }
            }
            if (months.first?.column ?? .max) >= 3 { months.insert((0, stats.first), at: 0) }
            for m in months {
                let x = geo.rect(GridCell(column: m.column, row: 0)).minX
                ctx.draw(label(m.date.formatted(.dateTime.month(.abbreviated))), at: CGPoint(x: x, y: 0), anchor: .topLeading)
            }

            let radius = max(1.5, geo.cell * 0.22)
            for column in 0..<stats.weeks {
                for row in 0..<7 {
                    let day = stats.date(column: column, row: row)
                    guard day <= stats.today else { continue }
                    let rect = geo.rect(GridCell(column: column, row: row))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: radius),
                             with: .color(HeatScale.color(stats.scale.level(stats.value(on: day)))))
                    if day == focus {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: radius + 1),
                                   with: .color(.primary), lineWidth: 1.5)
                    } else if day == stats.today {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius),
                                   with: .color(.primary.opacity(0.45)), lineWidth: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Small cells leave the last weekday label hanging below the grid; make room so it isn't clipped.
        .frame(height: geo.height + max(0, 6 - geo.cell / 2))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hovered = day(at: p)
            case .ended: hovered = nil
            }
        }
        .onTapGesture { p in
            guard let d = day(at: p) else { return }
            selected = selected == d ? nil : d
        }
        .accessibilityElement()
        .accessibilityLabel("Activity heatmap")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Adjust to move between days")
        .accessibilityAdjustableAction { direction in
            let current = selected ?? stats.today
            let step = direction == .increment ? 1 : -1
            if let next = stats.calendar.date(byAdding: .day, value: step, to: current), stats.contains(next) {
                selected = next
            }
        }
    }

    private func day(at p: CGPoint) -> Date? {
        guard let c = geometry.hitTest(p) else { return nil }
        let d = stats.date(column: c.column, row: c.row)
        return d <= stats.today ? d : nil
    }

    private var accessibilityValue: String {
        let day = selected ?? stats.today
        let v = stats.value(on: day)
        return "\(day.formatted(.dateTime.weekday(.wide).month(.wide).day())): \(v > 0 ? stats.metric.format(v) : "no activity")"
    }
}

// MARK: - Day detail

struct DayDetailCard: View {
    let day: Date
    let isToday: Bool
    let isPinned: Bool
    let stat: DayStat?
    let peak: Double?
    let sessions: [CodeSession]
    let metric: GridMetric
    let showsCode: Bool
    let onUnpin: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                        .font(.subheadline.weight(.semibold))
                    if isToday {
                        Text("TODAY").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                    }
                    Spacer()
                    if isPinned {
                        Button(action: onUnpin) { Image(systemName: "pin.slash") }
                            .buttonStyle(.borderless)
                            .help("Unpin this day")
                    }
                }

                HStack(alignment: .top, spacing: 0) {
                    if showsCode {
                        figure("Cost", stat.map { Fmt.money($0.cost) }, .cost)
                        figure("Tokens", stat.map { Fmt.tokens($0.tokens) }, .tokens)
                        figure("Responses", stat.map { Fmt.count($0.messages) }, .messages)
                    }
                    figure("Limit peak", peak.map { "\(Int($0.rounded()))%" }, .peak)
                }

                if !sessions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions.prefix(3)) { s in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title).font(.caption.weight(.medium)).lineLimit(1)
                                    Text("\(s.project) · \(s.start.formatted(date: .omitted, time: .shortened)) · \(Fmt.duration(s.duration))")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(Fmt.money(s.cost)).font(.caption.weight(.semibold)).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if sessions.count > 3 {
                            Text("+ \(sessions.count - 3) more session\(sessions.count == 4 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                } else if stat == nil && peak == nil {
                    Text(isToday ? "Nothing yet today." : "No activity on this day.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func figure(_ label: String, _ value: String?, _ m: GridMetric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(value == nil ? Color.secondary : m == metric ? Theme.accent : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Weekday × hour

struct WeekHourCard: View {
    let stats: WeekHourStats
    let metric: GridMetric
    let range: ActivityRange
    @State private var hovered: GridCell?
    @State private var width: CGFloat = 388

    private var geometry: GridGeometry {
        GridGeometry(width: width, columns: 24, rows: 7, leading: 28, top: 14, maxCell: 14, gapRatio: 0.2)
    }

    private var valueMetric: GridMetric { metric == .peak ? .messages : metric }

    var body: some View {
        let geo = geometry
        Card {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("When you use Claude Code").font(.subheadline.weight(.semibold))
                    Text("\(valueMetric.rawValue) by weekday and hour · \(range.title.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Canvas { ctx, _ in
                    let label = { (s: String) in Text(s).font(.system(size: 9)).foregroundColor(.secondary) }
                    for row in 0..<7 {
                        let r = geo.rect(GridCell(column: 0, row: row))
                        ctx.draw(label(Self.weekday(row)), at: CGPoint(x: geo.labelX, y: r.midY), anchor: .leading)
                    }
                    for hour in stride(from: 0, to: 24, by: 6) {
                        let r = geo.rect(GridCell(column: hour, row: 0))
                        ctx.draw(label(Self.hourLabel(hour)), at: CGPoint(x: r.minX, y: 0), anchor: .topLeading)
                    }
                    let radius = max(1.5, geo.cell * 0.22)
                    for row in 0..<7 {
                        for hour in 0..<24 {
                            let c = GridCell(column: hour, row: row)
                            let rect = geo.rect(c)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: radius),
                                     with: .color(HeatScale.color(stats.scale.level(stats.cells[row][hour]))))
                            if c == hovered {
                                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: radius + 1),
                                           with: .color(.primary), lineWidth: 1.5)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geo.height)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hovered = geometry.hitTest(p)
                    case .ended: hovered = nil
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Activity by weekday and hour")
                .accessibilityValue(caption)

                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var caption: String {
        if let c = hovered {
            let v = stats.cells[c.row][c.column]
            return "\(Self.weekday(c.row)) \(Self.hourLabel(c.column))–\(Self.hourLabel((c.column + 1) % 24)): "
                + (v > 0 ? valueMetric.format(v) : "no activity")
        }
        guard let b = stats.busiest else { return "No Claude Code activity in this range." }
        let share = stats.total > 0 ? Int((b.value / stats.total * 100).rounded()) : 0
        return "Busiest: \(Self.weekday(b.cell.row)) around \(Self.hourLabel(b.cell.column)) · \(share)% of \(valueMetric.rawValue.lowercased())"
    }

    private static func weekday(_ row: Int) -> String {
        let cal = Calendar.current
        return cal.shortWeekdaySymbols[(cal.firstWeekday - 1 + row) % 7]
    }

    private static func hourLabel(_ hour: Int) -> String {
        guard let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { return "\(hour)" }
        return d.formatted(.dateTime.hour())
    }
}
