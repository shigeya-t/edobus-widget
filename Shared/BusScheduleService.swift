import Foundation

struct BusTime: Comparable, Hashable {
    let hour: Int
    let minute: Int

    static func < (lhs: BusTime, rhs: BusTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    func date(on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }
}

enum BusScheduleService {
    /// 時刻表は日をまたがない限り変わらないため、停留所・曜日区分ごとに保持して再取得を避ける。
    private static let cache = TimetableCache()

    /// 指定した停留所の時刻表を取得する。
    ///
    /// レスポンスは曜日区分ごとのレコードで、1レコードが1時間帯を表す。
    /// 例: <type>0</type><hour>8</hour><minute>07 27 47</minute>
    /// minuteが空のレコードは運行のない時間帯なので結果に含まれない。
    static func fetchTimetable(stop: BusStop, dayType: ScheduleDayType) async throws -> [BusTime] {
        let key = "\(stop.id):\(dayType.rawValue)"
        if let cached = await cache.value(for: key) { return cached }

        let data = try await BusAPI.fetch(
            path: "get_time_table_info.php",
            query: [
                "bccd": BusStopConfig.companyCode,
                "rtcd": stop.routeCode,
                "bscd": stop.code
            ]
        )

        let records = XMLRecordParser(recordElement: "get_time_table_info").parse(data)
        let times = records
            .filter { Int($0["type"] ?? "") == dayType.rawValue }
            .flatMap { record -> [BusTime] in
                guard let hour = Int(record["hour"] ?? "") else { return [] }
                let minutes = (record["minute"] ?? "")
                    .split(whereSeparator: { $0.isWhitespace })
                    .compactMap { Int($0) }
                return minutes.map { BusTime(hour: hour, minute: $0) }
            }
            .sorted()

        await cache.store(times, for: key)
        return times
    }
}

private actor TimetableCache {
    private var entries: [String: (times: [BusTime], day: Date)] = [:]

    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BusStopConfig.timeZone
        return calendar.startOfDay(for: Date())
    }

    func value(for key: String) -> [BusTime]? {
        guard let entry = entries[key], entry.day == today else { return nil }
        return entry.times
    }

    func store(_ times: [BusTime], for key: String) {
        entries[key] = (times, today)
    }
}
