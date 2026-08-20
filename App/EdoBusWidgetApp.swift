import SwiftUI
import WidgetKit
import AppIntents

@main
struct EdoBusWidgetApp: App {
    @StateObject private var model = ArrivalModel()

    var body: some Scene {
        // メニューバー常駐。ここから定期的にウィジェットを更新するため、
        // ウィジェット単体では更新されない macOS の制約を回避できる。
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label(model.menuBarTitle, systemImage: model.isPaused ? "bus" : "bus.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class ArrivalModel: ObservableObject {
    /// 常駐中の取得間隔。元データが分単位のため、これ以上短くしても表示は変わらない。
    private static let refreshInterval: TimeInterval = 60

    @Published var routes: [BusRoute] = []
    @Published var stops: [BusStop] = []
    @Published var selectedRoute: BusRoute? {
        didSet {
            guard selectedRoute != oldValue else { return }
            selectionGeneration += 1
            Task { await routeChanged(generation: selectionGeneration) }
        }
    }
    @Published var selectedStop: BusStop? {
        didSet {
            guard selectedStop != oldValue else { return }
            saveSelection()
            selectionGeneration += 1
            Task { await refresh(generation: selectionGeneration) }
        }
    }

    @Published var approach: BusApproach?
    @Published var scheduled: [Date] = []
    @Published var errorText: String?
    /// 一時停止中は定期取得を行わない。設定は次回起動にも引き継ぐ。
    @Published private(set) var isPaused: Bool

    private var timer: Timer?
    private var directoryLoaded = false
    /// 選択が変わるたびに増やす。await から戻った結果が古い選択のものなら破棄する。
    private var selectionGeneration = 0

    init() {
        isPaused = AppSettings.isPaused
        // 一時停止中は路線一覧すら取りに行かず、通信を完全に止める
        if !isPaused {
            Task { await activate() }
        }
        observePauseChangesFromWidget()
        observeManualRefreshRequestsFromWidget()
    }

    /// ウィジェット上のボタンで切り替えられた場合に追従する。
    /// App Group の設定変更は別プロセスへ自動通知されないため、通知で受け取る。
    private func observePauseChangesFromWidget() {
        DistributedNotificationCenter.default().addObserver(
            forName: .busPauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncPauseState() }
        }
    }

    /// ウィジェットの「今すぐ更新」は通信せずAppに委ねているため、要求を受けて代わりに取得する。
    private func observeManualRefreshRequestsFromWidget() {
        DistributedNotificationCenter.default().addObserver(
            forName: .busManualRefreshRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
    }

    private func syncPauseState() {
        let shared = AppSettings.isPaused
        guard shared != isPaused else { return }
        if shared {
            pause(propagate: false)
        } else {
            resume(propagate: false)
        }
    }

    /// メニューバーに出す短い文字列
    var menuBarTitle: String {
        if isPaused { return "停止中" }
        guard let state = approach?.state else { return "--" }
        switch state {
        case .approaching(let minutes, let isAtLeast, _):
            return isAtLeast ? "\(minutes)分+" : "\(minutes)分"
        case .imminent: return "まもなく"
        case .arrived: return "到着"
        case .departed: return "発車"
        case .notStarted: return "始発待ち"
        case .longWait: return "しばらくなし"
        case .finished: return "運行終了"
        case .unknown: return "--"
        }
    }

    // MARK: - 開始 / 一時停止

    /// メニューを開いたとき。一時停止中でもバス停を選べるよう、一覧だけは読み込む。
    func prepareForDisplay() async {
        await loadDirectoryIfNeeded()
    }

    /// - Parameter propagate: ウィジェット側へ反映する。ウィジェット発の変更を受けた場合は false。
    func pause(propagate: Bool = true) {
        isPaused = true
        timer?.invalidate()
        timer = nil
        if propagate {
            AppSettings.isPaused = true
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func resume(propagate: Bool = true) {
        isPaused = false
        if propagate {
            AppSettings.isPaused = false
        }
        Task { await activate() }
    }

    private func activate() async {
        await loadDirectoryIfNeeded()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        await refresh(force: true)
    }

    private func loadDirectoryIfNeeded() async {
        guard !directoryLoaded else { return }
        do {
            // 空の一覧はエラーになるため、ここで成功したら必ず中身がある
            routes = try await BusDirectoryService.fetchRoutes()
        } catch {
            // 取得できなかった場合は既読にせず、次の機会に再試行する
            errorText = "路線一覧を取得できません: \(error.localizedDescription)"
            return
        }
        directoryLoaded = true

        let saved = loadSelection()
        selectedRoute = routes.first { $0.code == saved.routeCode } ?? routes.first
    }

    private func routeChanged(generation: Int) async {
        guard let route = selectedRoute else { return }
        let fetched = (try? await BusDirectoryService.fetchStops(routeCode: route.code)) ?? []
        // 取得中に路線が切り替わっていたら、古い結果で上書きしない
        guard generation == selectionGeneration, selectedRoute == route else { return }

        stops = fetched
        let saved = loadSelection()
        selectedStop = fetched.first { $0.code == saved.stopCode && route.code == saved.routeCode }
            ?? fetched.first
    }

    /// - Parameters:
    ///   - force: 一時停止中でも取得する（「今すぐ更新」など明示操作のとき）
    ///   - generation: 取得開始時点の選択世代。省略時は現在の選択に追従する。
    func refresh(force: Bool = false, generation: Int? = nil) async {
        guard force || !isPaused else { return }
        guard let stop = selectedStop else { return }
        let generation = generation ?? selectionGeneration

        /// 取得中にバス停が切り替わっていないか
        func isCurrent() -> Bool {
            generation == selectionGeneration && selectedStop == stop
        }

        do {
            let result = try await BusLocationService.fetchApproach(stop: stop)
            AppSettings.saveSnapshot(
                .init(message: result.rawMessage, observedAt: result.observedAt),
                stopID: stop.id
            )
            guard isCurrent() else { return }
            approach = result
            errorText = nil
        } catch {
            guard isCurrent() else { return }
            errorText = error.localizedDescription
        }

        let dayType = await HolidayChecker.dayType(for: Date())
        if let times = try? await BusScheduleService.fetchTimetable(stop: stop, dayType: dayType) {
            guard isCurrent() else { return }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = BusStopConfig.timeZone
            let now = Date()
            scheduled = times
                .compactMap { $0.date(on: now, calendar: calendar) }
                .filter { $0 > now }
        }

        // 到着見込みの取得はここに一本化しているため、メニューバーとは別のバス停を
        // 表示しているウィジェットの分もあわせて取得しておく（ウィジェット側は通信しない）。
        await refreshWidgetOnlyApproaches(excluding: stop.id)

        // 配置済みウィジェットを更新する。
        // WidgetKit は自前のタイムライン要求をほとんど実行しないため、ここが実質の更新契機になる。
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// メニューバーの選択とは別のバス停を表示しているウィジェットの到着見込みを取得し、共有ストレージへ保存する。
    /// ウィジェット拡張はもう自分では通信せず、ここで保存したスナップショットを読むだけになる。
    private func refreshWidgetOnlyApproaches(excluding excludedStopID: String) async {
        let stops = await widgetConfiguredStops().filter { $0.id != excludedStopID }
        guard !stops.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for stop in stops {
                group.addTask {
                    guard let result = try? await BusLocationService.fetchApproach(stop: stop) else { return }
                    AppSettings.saveSnapshot(
                        .init(message: result.rawMessage, observedAt: result.observedAt),
                        stopID: stop.id
                    )
                }
            }
        }
    }

    /// 配置中の各ウィジェットが表示しているバス停（重複なし）。
    private func widgetConfiguredStops() async -> [BusStop] {
        let infos: [WidgetInfo]
        do {
            infos = try await withCheckedThrowingContinuation { continuation in
                WidgetCenter.shared.getCurrentConfigurations { continuation.resume(with: $0) }
            }
        } catch {
            return []
        }

        var seen = Set<String>()
        var stops: [BusStop] = []
        for info in infos {
            guard let intent = info.configuration as? SelectEdoBusStopIntent else { continue }
            let stop = await intent.resolvedStop()
            if seen.insert(stop.id).inserted {
                stops.append(stop)
            }
        }
        return stops
    }

    // MARK: - 選択の保存

    private func saveSelection() {
        guard let stop = selectedStop else { return }
        AppSettings.selectedRouteCode = stop.routeCode
        AppSettings.selectedStopCode = stop.code
    }

    private func loadSelection() -> (routeCode: String, stopCode: String) {
        (AppSettings.selectedRouteCode, AppSettings.selectedStopCode)
    }
}

struct MenuContent: View {
    @ObservedObject var model: ArrivalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            picker
            Divider()
            status
            scheduleRow
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .task { await model.prepareForDisplay() }
    }

    private var picker: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("路線").foregroundStyle(.secondary)
                Picker("", selection: $model.selectedRoute) {
                    ForEach(model.routes) { route in
                        Text(route.name).tag(Optional(route))
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("バス停").foregroundStyle(.secondary)
                Picker("", selection: $model.selectedStop) {
                    ForEach(model.stops) { stop in
                        Text(stop.name).tag(Optional(stop))
                    }
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var scheduleRow: some View {
        if !model.scheduled.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("定刻")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Array(model.scheduled.prefix(4).enumerated()), id: \.offset) { _, date in
                        Text(date, format: .dateTime.hour().minute())
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let errorText = model.errorText {
            Label(errorText, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let approach = model.approach {
            VStack(alignment: .leading, spacing: 6) {
                arrivalText(approach)
                Text("バスロケーション情報 · \(approach.observedAt, format: .dateTime.hour().minute().second()) 時点")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if model.isPaused {
                    Label("一時停止中（自動更新なし）", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if model.isPaused {
            Label("一時停止中", systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func arrivalText(_ approach: BusApproach) -> some View {
        switch approach.state {
        case .approaching(let minutes, let isAtLeast, let nearStopName):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isAtLeast ? "約\(minutes)分以上" : "約\(minutes)分後")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                if let nearStopName {
                    Text("（現在 \(nearStopName) 付近）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .imminent:
            Text("まもなく到着")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
        case .arrived:
            Text("到着しました")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
        case .departed:
            Text("発車しました")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
        case .notStarted:
            VStack(alignment: .leading, spacing: 2) {
                Text("運行開始前")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                if let arrival = approach.predictedArrival {
                    Text("始発 \(arrival, format: .dateTime.hour().minute()) 頃到着見込み")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .longWait:
            VStack(alignment: .leading, spacing: 2) {
                Text("しばらく到着なし")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                if let arrival = approach.predictedArrival {
                    Text("次は \(arrival, format: .dateTime.hour().minute()) 頃到着見込み")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .finished:
            Text("本日の運行は終了しました")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        case .unknown(let message):
            Text(message.isEmpty ? "運行情報を取得できません" : message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: URL(string: "http://edobus.bus-go.com/")!) {
                Label("BusGO! バスロケーションシステムで見る", systemImage: "map")
                    .font(.caption)
            }

            Text("ウィジェット側のバス停は、ウィジェットを右クリックして「ウィジェットを編集」から個別に設定できます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(model.isPaused ? "再開" : "一時停止") {
                    if model.isPaused { model.resume() } else { model.pause() }
                }
                Button("今すぐ更新") {
                    Task { await model.refresh(force: true) }
                }
                Spacer()
                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
        }
    }
}
