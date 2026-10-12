import Foundation

/// Persists the meaning of a date shortcut, rather than its resolved dates.
/// Only a custom selection has fixed start and end timestamps.
public final class UsageDateSelectionStore {
    public static let storageKey = "UsageDateSelectionV1"

    private enum StoredPreset: String, Codable {
        case today, week, month, limitPeriod, custom

        init(_ preset: DatePreset) {
            switch preset {
            case .today: self = .today
            case .week: self = .week
            case .month: self = .month
            case .limitPeriod: self = .limitPeriod
            case .custom: self = .custom
            }
        }

        var preset: DatePreset {
            switch self {
            case .today: .today
            case .week: .week
            case .month: .month
            case .limitPeriod: .limitPeriod
            case .custom: .custom
            }
        }
    }

    private struct Selection: Codable {
        let preset: StoredPreset
        let startDate: Date?
        let endDate: Date?
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(now: Date = Date(), calendar: Calendar = .current) -> UsageFilter {
        var filter = UsageFilter(now: now, calendar: calendar)
        guard
            let data = defaults.data(forKey: Self.storageKey),
            let selection = try? JSONDecoder().decode(Selection.self, from: data)
        else { return filter }

        switch selection.preset {
        case .custom:
            guard
                let start = selection.startDate, start.timeIntervalSinceReferenceDate.isFinite,
                let end = selection.endDate, end.timeIntervalSinceReferenceDate.isFinite
            else { return filter }
            filter.startDate = start
            filter.endDate = end
            filter.preset = .custom
        case .limitPeriod:
            // The dashboard resolves this after loading the current server
            // window. Until then, its placeholder dates must not be displayed.
            filter.preset = .limitPeriod
        case .today, .week, .month:
            filter.apply(selection.preset.preset, now: now, calendar: calendar)
        }
        return filter
    }

    public func save(_ filter: UsageFilter) {
        let selection = Selection(
            preset: StoredPreset(filter.preset),
            startDate: filter.preset == .custom ? filter.startDate : nil,
            endDate: filter.preset == .custom ? filter.endDate : nil
        )
        guard
            let data = try? JSONEncoder().encode(selection),
            data != defaults.data(forKey: Self.storageKey)
        else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
