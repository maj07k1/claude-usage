import Foundation
import Testing
@testable import ClaudeUsage

/// Fixed calendar and clock so results don't depend on the machine running the tests.
private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = 1      // Sunday
    return c
}()

/// Wednesday 14 October 2026, mid-afternoon.
private let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15))!
private let today = cal.startOfDay(for: now)

private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

@Suite struct HeatScaleTests {
    @Test func zeroIsEmpty() {
        #expect(HeatScale(values: [1, 2, 3]).level(0) == 0)
    }

    @Test func singleActiveDayIsFullStrength() {
        #expect(HeatScale(values: [5]).level(5) == 4)
    }

    @Test func ranksAreQuartiles() {
        let s = HeatScale(values: [1, 2, 3, 4, 5, 6, 7, 8])
        #expect([1, 2, 3, 4, 5, 6, 7, 8].map { s.level($0) } == [1, 1, 2, 2, 3, 3, 4, 4])
    }

    @Test func outlierDoesNotWashOutTheRest() {
        let s = HeatScale(values: [1, 1, 1, 1000])
        #expect(s.level(1) == 3)
        #expect(s.level(1000) == 4)
    }

    @Test func fixedBounds() {
        let s = HeatScale(bounds: [25, 50, 75])
        #expect([10, 25, 49, 50, 80, 100].map { s.level($0) } == [1, 2, 2, 3, 4, 4])
    }
}

@Suite struct ActivityStatsTests {
    @Test func gridStartsOnFirstWeekdayAndEndsToday() {
        let s = ActivityStats(metric: .cost, values: [:], weeks: 26, now: now, calendar: cal)
        #expect(cal.component(.weekday, from: s.first) == cal.firstWeekday)
        // Today is a Wednesday: the last column holds Sun, Mon, Tue, Wed.
        #expect(s.cell(for: today) == GridCell(column: 25, row: 3))
        #expect(s.dayCount == 25 * 7 + 4)
        #expect(s.date(column: 25, row: 3) == today)
    }

    @Test func totalsOnlyCountTheRange() {
        let values: [Date: Double] = [day(0): 10, day(-1): 5, day(-400): 99, day(-3): 0]
        let s = ActivityStats(metric: .cost, values: values, weeks: 13, now: now, calendar: cal)
        #expect(s.total == 15)
        #expect(s.activeDays == 2)
        #expect(s.average == 7.5)
        #expect(s.best?.date == day(0))
    }

    @Test func comparesWithTheSameLengthPeriodBefore() {
        let probe = ActivityStats(metric: .cost, values: [:], weeks: 13, now: now, calendar: cal)
        let beforeStart = cal.date(byAdding: .day, value: -1, to: probe.first)!
        let tooEarly = cal.date(byAdding: .day, value: -(probe.dayCount + 1), to: probe.first)!
        let s = ActivityStats(metric: .cost, values: [day(0): 30, beforeStart: 20, tooEarly: 1000],
                              weeks: 13, now: now, calendar: cal)
        #expect(s.previousTotal == 20)
        #expect(s.change == 50)
    }

    @Test func noPreviousPeriodMeansNoChange() {
        let s = ActivityStats(metric: .cost, values: [day(0): 30], weeks: 13, now: now, calendar: cal)
        #expect(s.change == nil)
    }

    @Test func tieForBestDayPicksTheLatest() {
        let s = ActivityStats(metric: .messages, values: [day(-5): 7, day(-2): 7, day(-9): 3],
                              weeks: 13, now: now, calendar: cal)
        #expect(s.best?.date == day(-2))
    }

    @Test func limitMetricCountsNearLimitDays() {
        let s = ActivityStats(metric: .peak, values: [day(0): 95, day(-1): 90, day(-2): 40],
                              weeks: 13, now: now, calendar: cal)
        #expect(s.nearLimitDays == 2)
        #expect(s.scale.level(40) == 2)
    }

    @Test func cellRoundTrips() {
        let s = ActivityStats(metric: .cost, values: [:], weeks: 52, now: now, calendar: cal)
        for c in [GridCell(column: 0, row: 0), GridCell(column: 17, row: 4), GridCell(column: 51, row: 3)] {
            #expect(s.cell(for: s.date(column: c.column, row: c.row)) == c)
        }
        #expect(s.cell(for: day(-400)) == nil)
        #expect(!s.contains(day(1)))
    }
}

@Suite struct StreakTests {
    @Test func currentStreakSurvivesUntilTomorrow() {
        let days: Set<Date> = [day(-1), day(-2), day(-3), day(-10)]
        let s = InsightsEngine.streaks(days, now: now, calendar: cal)
        #expect(s.current == 3)
        #expect(s.longest == 3)
    }

    @Test func gapEndsTheCurrentStreak() {
        let s = InsightsEngine.streaks([day(-2), day(-3)], now: now, calendar: cal)
        #expect(s.current == 0)
        #expect(s.longest == 2)
    }

    @Test func emptyHistory() {
        let s = InsightsEngine.streaks([], now: now, calendar: cal)
        #expect(s.current == 0 && s.longest == 0)
    }
}

@Suite struct WeekHourTests {
    @Test func foldsHoursOntoWeekdayRows() {
        // Wednesday 15:00 in two different weeks, and Sunday 09:00.
        let wed = cal.date(byAdding: .hour, value: 15, to: today)!
        let lastWed = cal.date(byAdding: .day, value: -7, to: wed)!
        let sun = cal.date(byAdding: .hour, value: 9, to: day(-3))!
        let hours: [Date: DayStat] = [
            wed: DayStat(cost: 1, tokens: 10, messages: 2),
            lastWed: DayStat(cost: 2, tokens: 20, messages: 3),
            sun: DayStat(cost: 4, tokens: 5, messages: 1),
        ]
        let s = WeekHourStats(hours: hours, metric: .messages, from: day(-30), calendar: cal)
        #expect(s.cells[3][15] == 5)
        #expect(s.cells[0][9] == 1)
        #expect(s.total == 6)
        #expect(s.busiest?.cell == GridCell(column: 15, row: 3))

        let recent = WeekHourStats(hours: hours, metric: .cost, from: day(-5), calendar: cal)
        #expect(recent.cells[3][15] == 1)
    }

    @Test func limitMetricFallsBackToResponses() {
        let h = cal.date(byAdding: .hour, value: 2, to: today)!
        let s = WeekHourStats(hours: [h: DayStat(cost: 9, tokens: 9, messages: 4)], metric: .peak, from: day(-1), calendar: cal)
        #expect(s.total == 4)
    }
}

@Suite struct GridGeometryTests {
    @Test func fillsWidthAndHitTestsCells() {
        let g = GridGeometry(width: 388, columns: 26, rows: 7, leading: 24, top: 14, maxCell: 18)
        let last = g.rect(GridCell(column: 25, row: 6))
        #expect(abs(last.maxX - 388) < 0.5)
        #expect(g.hitTest(CGPoint(x: last.midX, y: last.midY)) == GridCell(column: 25, row: 6))
        #expect(g.hitTest(CGPoint(x: 5, y: 5)) == nil)
    }

    @Test func capsCellSizeAndCenters() {
        let g = GridGeometry(width: 388, columns: 13, rows: 7, leading: 24, top: 14, maxCell: 18)
        #expect(g.cell == 18)
        let right = 388 - g.rect(GridCell(column: 12, row: 0)).maxX
        #expect(abs(right - g.labelX) < 0.5)
    }
}

@Suite struct FormattingTests {
    @Test func counts() {
        #expect(Fmt.count(950) == 950.formatted())
        #expect(Fmt.count(12_345) == "12K")
    }

    @Test func usageDatesWithMicroseconds() {
        let micro = UsageParser.parseDate("2026-10-14T15:00:00.943648+00:00")
        #expect(micro.map { abs($0.timeIntervalSince(now)) < 1 } == true)
        #expect(UsageParser.parseDate("2026-10-14T15:00:00Z") == now)
    }
}
