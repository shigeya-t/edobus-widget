import WidgetKit
import SwiftUI
import AppIntents

struct BusEntry: TimelineEntry {
    let date: Date
    let stop: BusStop
    let routeName: String
    /// バスロケーション（GPS）由来の接近状況。取得できなかった場合はnil。
    let approach: BusApproach?
    /// 時刻表由来の今後の定刻。リアルタイム情報の補助として表示する。
    let scheduled: [Date]
    let dayLabel: String
    let isNextDay: Bool
    /// 一時停止中は通信せず、最後に取得した値をそのまま表示する
    let isPaused: Bool

    static func placeholder(_ date: Date = Date()) -> BusEntry {
        BusEntry(
            date: date,
            stop: BusStopConfig.defaultStop,
            routeName: BusStopConfig.defaultRoute.name,
            approach: nil,
            scheduled: [],
            dayLabel: "",
            isNextDay: false,
            isPaused: false
        )
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BusEntry {
        BusEntry.placeholder()
    }

    func snapshot(for configuration: SelectBusStopIntent, in context: Context) async -> BusEntry {
        await buildEntry(configuration: configuration, now: Date())
    }

    func timeline(for configuration: SelectBusStopIntent, in context: Context) async -> Timeline<BusEntry> {
        let now = Date()
        let entry = await buildEntry(configuration: configuration, now: now)
        return Timeline(entries: [entry], policy: .after(reloadDate(for: entry, now: now)))
    }

    /// GPS情報を取り直すタイミング。
    /// 残り分数はサーバーが算出した値をそのまま表示するため、
    /// 表示を新しく保てるかはこの更新間隔で決まる。
    private func reloadDate(for entry: BusEntry, now: Date) -> Date {
        // 一時停止中は自発的な更新要求を出さない（リロードボタンで明示的に更新する）
        if entry.isPaused {
            return now.addingTimeInterval(60 * 60)
        }

        let interval: TimeInterval
        switch entry.approach?.state {
        case .approaching:
            // 到着直後に次のバスへ切り替えたいので、到着予測の少し後か3分後の早い方
            if let arrival = entry.approach?.predictedArrival {
                interval = min(max(arrival.timeIntervalSince(now) + 60, 60), 180)
            } else {
                interval = 180
            }
        case .imminent, .arrived, .departed:
            interval = 90
        case .finished, .unknown:
            // 運行終了、または解釈できないメッセージ。
            // 次の定刻が分かっていればその少し前まで待ち、無駄な更新を減らす。
            if let next = entry.scheduled.first {
                interval = min(max(next.timeIntervalSince(now) - 300, 5 * 60), 60 * 60)
            } else {
                interval = 20 * 60
            }
        case .none:
            // 取得失敗。一時的な通信エラーの可能性があるため長く空けない。
            interval = 5 * 60
        }
        return now.addingTimeInterval(interval)
    }

    private func buildEntry(configuration: SelectBusStopIntent, now: Date) async -> BusEntry {
        // 停留所の解決や路線名の取得も通信を伴うため、一時停止の判定を最初に行う。
        // 停留所IDは設定値から通信なしで取得できる。
        let isPaused = AppSettings.isPaused
        let configuredStopID = configuration.stop?.id ?? BusStopConfig.defaultStop.id
        if isPaused, !AppSettings.hasManualRefresh(stopID: configuredStopID) {
            return pausedEntry(configuration: configuration, now: now)
        }

        let stop = await configuration.resolvedStop()
        let routeName = await BusDirectoryService.route(code: stop.routeCode)?.name ?? ""

        async let approachTask = try? await BusLocationService.fetchApproach(stop: stop)
        let dayType = await HolidayChecker.dayType(for: now)
        let times = (try? await BusScheduleService.fetchTimetable(stop: stop, dayType: dayType)) ?? []
        let approach = await approachTask

        // 一時停止中に表示する値として、取得結果を共有領域に残しておく
        if let approach {
            AppSettings.saveSnapshot(
                .init(message: approach.rawMessage, observedAt: approach.observedAt),
                stopID: stop.id
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BusStopConfig.timeZone

        let todaysRemaining = times
            .compactMap { $0.date(on: now, calendar: calendar) }
            .filter { $0 > now }

        if todaysRemaining.isEmpty, let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            let tomorrowType = await HolidayChecker.dayType(for: tomorrow)
            let tomorrowTimes = (try? await BusScheduleService.fetchTimetable(stop: stop, dayType: tomorrowType)) ?? []
            let tomorrowDates = tomorrowTimes.compactMap { $0.date(on: tomorrow, calendar: calendar) }
            return BusEntry(
                date: now,
                stop: stop,
                routeName: routeName,
                approach: approach,
                scheduled: Array(tomorrowDates.prefix(3)),
                dayLabel: tomorrowType.label,
                isNextDay: true,
                isPaused: isPaused
            )
        }

        return BusEntry(
            date: now,
            stop: stop,
            routeName: routeName,
            approach: approach,
            scheduled: Array(todaysRemaining.prefix(3)),
            dayLabel: dayType.label,
            isNextDay: false,
            isPaused: isPaused
        )
    }

    /// 一時停止中のエントリ。通信を一切せず、設定値と最後の取得結果だけで組み立てる。
    /// 停留所名・路線名はウィジェット設定に保存されている値をそのまま使う。
    private func pausedEntry(configuration: SelectBusStopIntent, now: Date) -> BusEntry {
        let stopID = configuration.stop?.id ?? BusStopConfig.defaultStop.id
        let defaultStopData = BusStop(id: stopID) ?? BusStopConfig.defaultStop
        let stop = BusStop(
            routeCode: defaultStopData.routeCode,
            code: defaultStopData.code,
            name: configuration.stop?.name ?? BusStopConfig.defaultStop.name
        )
        let routeName = configuration.route?.name ?? ""

        let approach = AppSettings.snapshot(stopID: stop.id).map { snapshot in
            BusApproach(
                state: BusLocationService.parseState(from: snapshot.message),
                observedAt: snapshot.observedAt,
                rawMessage: snapshot.message
            )
        }
        return BusEntry(
            date: now,
            stop: stop,
            routeName: routeName,
            approach: approach,
            scheduled: [],
            dayLabel: "",
            isNextDay: false,
            isPaused: true
        )
    }
}

struct EdoBusWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            liveStatus
            Spacer(minLength: 0)
            observedAtLine
            scheduleFooter
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(BusStopConfig.companyName) \(entry.routeName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.stop.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(intent: TogglePauseIntent()) {
                    Image(systemName: entry.isPaused ? "play.fill" : "pause.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(entry.isPaused ? .orange : .secondary)

                Button(intent: RefreshBusIntent(stopID: entry.stop.id)) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 表示値がいつ時点のものかを示す。一時停止中は値が固定されるため特に重要。
    @ViewBuilder
    private var observedAtLine: some View {
        if let observedAt = entry.approach?.observedAt {
            HStack(spacing: 4) {
                if entry.isPaused {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.orange)
                }
                Text("\(observedAt, format: .dateTime.hour().minute()) 時点")
                if entry.isPaused {
                    Text("· 一時停止中")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var liveStatus: some View {
        switch entry.approach?.state {
        case .approaching(let minutes, let isAtLeast, let nearStopName):
            VStack(alignment: .leading, spacing: 2) {
                // サーバーが算出した分数をそのまま表示する。
                // 元の見込みが分単位のため、秒送りのカウントダウンはしない。
                Text(isAtLeast ? "約\(minutes)分以上" : "約\(minutes)分後")
                    .font(.system(size: family == .systemSmall ? 26 : 32, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let nearStopName {
                    Label("（現在 \(nearStopName) 付近）", systemImage: "bus.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

        case .imminent:
            statusText("まもなく到着", color: .green, systemImage: "bus.fill")

        case .arrived:
            statusText("到着しました", color: .green, systemImage: "bus.fill")

        case .departed:
            statusText("発車しました", color: .orange, systemImage: "arrow.right")

        case .finished:
            statusText("本日の運行終了", color: .secondary, systemImage: "moon.zzz")

        case .unknown(let message):
            Text(message.isEmpty ? "運行情報を取得できません" : message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

        case .none:
            if entry.isPaused {
                Label("一時停止中", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("運行情報を取得できません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(_ text: String, color: Color, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.title3.bold())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private var scheduleFooter: some View {
        if !entry.scheduled.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.isNextDay ? "翌日（\(entry.dayLabel)）の始発" : "定刻")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    ForEach(Array(entry.scheduled.prefix(family == .systemSmall ? 2 : 3).enumerated()), id: \.offset) { _, date in
                        Text(date, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

struct EdoBusWidget: Widget {
    let kind: String = "EdoBusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectBusStopIntent.self, provider: Provider()) { entry in
            EdoBusWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("江戸バス")
        .description("選んだバス停に次のバスが到着するまでの時間を、バスロケーション情報から表示します。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
