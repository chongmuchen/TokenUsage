import Foundation
import Testing
@testable import TokenUsageCore

@Test("Saved relative date choices resolve against the reopening date", arguments: [
    DatePreset.today, .week, .month
])
func savedRelativeDateChoicesMoveToReopeningDate(_ preset: DatePreset) throws {
    try withDateSelectionDefaults { defaults in
        let calendar = dateSelectionCalendar()
        let originallyOpenedAt = dateSelectionDate(2026, 9, 30, hour: 22, calendar: calendar)
        let reopenedAt = dateSelectionDate(2026, 10, 2, hour: 17, calendar: calendar)
        var original = UsageFilter(now: originallyOpenedAt, calendar: calendar)
        original.apply(preset, now: originallyOpenedAt, calendar: calendar)
        UsageDateSelectionStore(defaults: defaults).save(original)

        // A fresh store models an app relaunch, rather than reusing memory.
        let restored = UsageDateSelectionStore(defaults: defaults).load(
            now: reopenedAt,
            calendar: calendar
        )
        let expectedStart: Date
        switch preset {
        case .today:
            expectedStart = dateSelectionDate(2026, 10, 2, calendar: calendar)
        case .week:
            expectedStart = dateSelectionDate(2026, 9, 26, calendar: calendar)
        case .month:
            expectedStart = dateSelectionDate(2026, 9, 3, calendar: calendar)
        case .limitPeriod, .custom:
            Issue.record("Unexpected relative preset")
            return
        }

        #expect(restored.preset == preset)
        #expect(restored.startDate == expectedStart)
        #expect(restored.endDate == dateSelectionDate(
            2026, 10, 2, hour: 23, minute: 59, calendar: calendar
        ))
        #expect(restored.startDate != original.startDate)
        #expect(restored.endDate != original.endDate)
    }
}

@Test("Custom dates retain exact minutes and reversed picker order across relaunch")
func savedCustomDateChoicesRetainExactDates() throws {
    try withDateSelectionDefaults { defaults in
        let calendar = dateSelectionCalendar()
        var original = UsageFilter(
            now: dateSelectionDate(2026, 9, 30, calendar: calendar),
            calendar: calendar
        )
        original.startDate = dateSelectionDate(2026, 9, 28, hour: 18, minute: 47, calendar: calendar)
        original.endDate = dateSelectionDate(2026, 9, 25, hour: 9, minute: 12, calendar: calendar)
        original.preset = .custom
        UsageDateSelectionStore(defaults: defaults).save(original)

        let restored = UsageDateSelectionStore(defaults: defaults).load(
            now: dateSelectionDate(2026, 10, 2, calendar: calendar),
            calendar: calendar
        )

        #expect(restored.preset == .custom)
        #expect(restored.startDate == original.startDate)
        #expect(restored.endDate == original.endDate)
        #expect(restored.startDate > restored.endDate)
        #expect(restored.minuteRange(calendar: calendar).lower == original.endDate)
        #expect(restored.minuteRange(calendar: calendar).upperExclusive == dateSelectionDate(
            2026, 9, 28, hour: 18, minute: 48, calendar: calendar
        ))
    }
}

@Test("Saved quota choice waits for a new window instead of restoring the previous window")
func savedQuotaChoiceUsesNewQuotaWindow() throws {
    try withDateSelectionDefaults { defaults in
        let calendar = dateSelectionCalendar()
        let previousNow = dateSelectionDate(2026, 9, 30, calendar: calendar)
        let reopenedAt = dateSelectionDate(2026, 10, 2, hour: 17, calendar: calendar)
        var original = UsageFilter(now: previousNow, calendar: calendar)
        let originalPeriodApplied = original.applyLimitPeriod(
            start: dateSelectionDate(2026, 9, 24, hour: 10, minute: 5, calendar: calendar),
            endExclusive: dateSelectionDate(2026, 10, 1, hour: 10, minute: 5, calendar: calendar),
            calendar: calendar
        )
        #expect(originalPeriodApplied)
        UsageDateSelectionStore(defaults: defaults).save(original)

        var restored = UsageDateSelectionStore(defaults: defaults).load(
            now: reopenedAt,
            calendar: calendar
        )
        let placeholder = UsageFilter(now: reopenedAt, calendar: calendar)
        #expect(restored.preset == .limitPeriod)
        #expect(restored.startDate == placeholder.startDate)
        #expect(restored.endDate == placeholder.endDate)
        #expect(restored.startDate != original.startDate)
        #expect(restored.endDate != original.endDate)

        let currentStart = dateSelectionDate(2026, 10, 1, hour: 10, minute: 5, calendar: calendar)
        let currentEnd = dateSelectionDate(2026, 10, 8, hour: 10, minute: 5, calendar: calendar)
        let currentPeriodApplied = restored.applyLimitPeriod(
            start: currentStart,
            endExclusive: currentEnd,
            calendar: calendar
        )
        #expect(currentPeriodApplied)
        #expect(restored.preset == .limitPeriod)
        #expect(restored.startDate == currentStart)
        #expect(restored.endDate == dateSelectionDate(
            2026, 10, 8, hour: 10, minute: 4, calendar: calendar
        ))
        #expect(restored.minuteRange(calendar: calendar).upperExclusive == currentEnd)
    }
}

@Test("Missing, corrupt, unknown, and incomplete saved choices use the default month", arguments: [
    "", "not JSON", "{}", "{\"preset\":\"unknown\"}",
    "{\"preset\":\"custom\"}",
    "{\"preset\":\"custom\",\"startDate\":0}",
    "{\"preset\":\"custom\",\"startDate\":\"invalid\",\"endDate\":0}"
])
func invalidSavedDateChoicesUseDefault(_ storedJSON: String) throws {
    try withDateSelectionDefaults { defaults in
        if !storedJSON.isEmpty {
            defaults.set(Data(storedJSON.utf8), forKey: UsageDateSelectionStore.storageKey)
        }
        let calendar = dateSelectionCalendar()
        let now = dateSelectionDate(2026, 10, 2, hour: 17, calendar: calendar)

        let restored = UsageDateSelectionStore(defaults: defaults).load(now: now, calendar: calendar)

        #expect(restored == UsageFilter(now: now, calendar: calendar))
    }
}

@Test("Switching from custom dates to a relative choice removes stored absolute dates", arguments: [
    DatePreset.today, .week, .month, .limitPeriod
])
func relativeDateChoicesDoNotKeepCustomDates(_ preset: DatePreset) throws {
    try withDateSelectionDefaults { defaults in
        let calendar = dateSelectionCalendar()
        let now = dateSelectionDate(2026, 9, 30, hour: 22, calendar: calendar)
        let store = UsageDateSelectionStore(defaults: defaults)
        var filter = UsageFilter(now: now, calendar: calendar)
        filter.startDate = dateSelectionDate(2026, 8, 12, hour: 14, minute: 6, calendar: calendar)
        filter.endDate = dateSelectionDate(2026, 8, 13, hour: 8, minute: 34, calendar: calendar)
        filter.preset = .custom
        store.save(filter)

        if preset == .limitPeriod {
            let periodApplied = filter.applyLimitPeriod(
                start: dateSelectionDate(2026, 9, 24, hour: 10, calendar: calendar),
                endExclusive: dateSelectionDate(2026, 10, 1, hour: 10, calendar: calendar),
                calendar: calendar
            )
            #expect(periodApplied)
        } else {
            filter.apply(preset, now: now, calendar: calendar)
        }
        store.save(filter)

        let data = try #require(defaults.data(forKey: UsageDateSelectionStore.storageKey))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["startDate"] == nil)
        #expect(object["endDate"] == nil)
        let reopened = UsageDateSelectionStore(defaults: defaults).load(
            now: dateSelectionDate(2026, 10, 2, calendar: calendar),
            calendar: calendar
        )
        #expect(reopened.preset == preset)
        #expect(reopened.startDate != dateSelectionDate(
            2026, 8, 12, hour: 14, minute: 6, calendar: calendar
        ))
    }
}

@Test("Saving date selection leaves unrelated filter fields and preferences at their defaults")
func dateSelectionPersistenceIsScopedToDates() throws {
    try withDateSelectionDefaults { defaults in
        defaults.set("keep me", forKey: "UnrelatedPreference")
        let calendar = dateSelectionCalendar()
        let now = dateSelectionDate(2026, 9, 30, hour: 22, calendar: calendar)
        var original = UsageFilter(now: now, calendar: calendar)
        original.startDate = dateSelectionDate(2026, 9, 25, hour: 9, minute: 12, calendar: calendar)
        original.endDate = dateSelectionDate(2026, 9, 28, hour: 18, minute: 47, calendar: calendar)
        original.preset = .custom
        original.minimumTokensText = "100k"
        original.maximumTokensText = "2M"
        original.tokenScope = .selectedRange
        UsageDateSelectionStore(defaults: defaults).save(original)

        let restored = UsageDateSelectionStore(defaults: defaults).load(now: now, calendar: calendar)

        #expect(restored.preset == .custom)
        #expect(restored.startDate == original.startDate)
        #expect(restored.endDate == original.endDate)
        #expect(restored.minimumTokensText.isEmpty)
        #expect(restored.maximumTokensText.isEmpty)
        #expect(restored.tokenScope == .sessionTotal)
        #expect(defaults.string(forKey: "UnrelatedPreference") == "keep me")
    }
}

private func withDateSelectionDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "TokenUsageDateSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

private func dateSelectionCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

private func dateSelectionDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 0,
    minute: Int = 0,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}
