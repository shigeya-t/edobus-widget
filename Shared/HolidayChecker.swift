import Foundation

/// BusGO!時刻表の曜日区分。0=平日, 1=土曜, 2=日曜・祝日
enum ScheduleDayType: Int {
    case weekday = 0
    case saturday = 1
    case sundayOrHoliday = 2

    var label: String {
        switch self {
        case .weekday: return "平日"
        case .saturday: return "土曜"
        case .sundayOrHoliday: return "日曜・祝日"
        }
    }
}

enum HolidayChecker {
    private static let apiURL = URL(string: "https://holidays-jp.github.io/api/v1/date.json")!

    /// 祝日一覧は年単位でしか変わらないため、取得結果を保持して再取得を避ける。
    /// holidays-jp は個人運営の無料 API なので、更新のたびに叩かないようにする。
    private static let cache = HolidayCache()

    /// 指定日の曜日区分を判定する。祝日判定はholidays-jp APIを使用し、
    /// 取得に失敗した場合は曜日のみで判定する（祝日は平日扱いになる）。
    static func dayType(for date: Date) async -> ScheduleDayType {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BusStopConfig.timeZone
        let weekday = calendar.component(.weekday, from: date) // 1=日, 7=土

        if weekday == 1 {
            return .sundayOrHoliday
        }
        if await isHoliday(date) {
            return .sundayOrHoliday
        }
        if weekday == 7 {
            return .saturday
        }
        return .weekday
    }

    private static func isHoliday(_ date: Date) async -> Bool {
        guard let holidays = try? await fetchHolidays() else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BusStopConfig.timeZone
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = BusStopConfig.timeZone
        let key = formatter.string(from: date)
        return holidays[key] != nil
    }

    private static func fetchHolidays() async throws -> [String: String] {
        if let cached = await cache.value() { return cached }
        let (data, _) = try await URLSession.shared.data(from: apiURL)
        let holidays = try JSONDecoder().decode([String: String].self, from: data)
        await cache.store(holidays)
        return holidays
    }
}

private actor HolidayCache {
    private var holidays: [String: String]?
    private var fetchedAt: Date?
    private let lifetime: TimeInterval = 24 * 60 * 60

    func value() -> [String: String]? {
        guard let holidays, let fetchedAt,
              Date().timeIntervalSince(fetchedAt) < lifetime
        else { return nil }
        return holidays
    }

    func store(_ holidays: [String: String]) {
        self.holidays = holidays
        self.fetchedAt = Date()
    }
}
