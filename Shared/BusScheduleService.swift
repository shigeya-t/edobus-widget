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

    /// 早発や分単位の丸めで、到着見込みが次の定刻よりわずかに早く出る分の許容幅。
    private static let earlyArrivalTolerance: TimeInterval = 2 * 60

    /// 定刻のうち、まだ到着していないバスの分を返す。
    ///
    /// 現在時刻以降で絞るだけだと、遅れて接近中の「次のバス」の定刻は既に過ぎているため消え、
    /// 次の次の便から表示されてしまう。到着見込みが次の定刻より前なら、接近中のバスは
    /// 直前の定刻の便が遅れているものとみなし、その定刻も先頭に残す。
    static func upcoming(_ times: [Date], now: Date, approach: BusApproach?) -> [Date] {
        let sorted = times.sorted()
        let future = sorted.filter { $0 > now }
        guard let lastPast = sorted.last(where: { $0 <= now }),
              let arrival = approach?.predictedArrival,
              // 古いスナップショット（到着見込みを大きく過ぎたもの）では判断しない
              arrival > now.addingTimeInterval(-earlyArrivalTolerance)
        else { return future }

        if let next = future.first, arrival >= next.addingTimeInterval(-earlyArrivalTolerance) {
            return future
        }
        return [lastPast] + future
    }

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
