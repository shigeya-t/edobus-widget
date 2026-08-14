import Foundation

extension Notification.Name {
    static let busPauseStateChanged = Notification.Name("jp.shigeya.EdoBusWidget.pauseStateChanged")
    /// ウィジェットの「今すぐ更新」は通信せず、Appに取得を依頼する（到着見込みの取得をAppに一本化しているため）。
    static let busManualRefreshRequested = Notification.Name("jp.shigeya.EdoBusWidget.manualRefreshRequested")
}

/// アプリとウィジェット拡張で共有する設定。
/// サンドボックスのコンテナは別々のため、App Group 経由でやり取りする。
enum AppSettings {
    /// App Group は macOS では Team ID プレフィックスが必須のため、値を固定できない。
    /// ビルド設定 APP_GROUP_ID から Info.plist に埋め込んだものを読み取る。
    static let appGroupID: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? ""
    }()

    /// App Group が使えない場合は標準のドメインに退避する。
    /// アプリとウィジェットで値を共有できなくなるため、原因を追えるよう記録する。
    private static var defaults: UserDefaults {
        guard !appGroupID.isEmpty, let shared = UserDefaults(suiteName: appGroupID) else {
            busLogger.error("App Group を利用できません（AppGroupID=\(appGroupID, privacy: .public)）")
            return .standard
        }
        return shared
    }

    private enum Keys {
        static let isPaused = "isPaused"
        static let manualRefreshAll = "manualRefreshAt"
        static func manualRefresh(_ stopID: String) -> String { "manualRefreshAt.\(stopID)" }
        static let routeCode = "selectedRouteCode"
        static let stopCode = "selectedStopCode"
        static func snapshot(_ stopID: String) -> String { "snapshot.\(stopID)" }
    }

    /// 一時停止中は、アプリもウィジェットも定期的な取得を行わない。
    static var isPaused: Bool {
        get { defaults.bool(forKey: Keys.isPaused) }
        set { defaults.set(newValue, forKey: Keys.isPaused) }
    }

    /// ウィジェットから切り替えたとき、常駐アプリ側にも伝える。
    /// App Group の設定変更は別プロセスに自動通知されないため、明示的に知らせる。
    static func notifyPauseStateChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .busPauseStateChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// ウィジェットの「今すぐ更新」ボタンから、到着見込みの取得元であるAppに通知する。
    static func notifyManualRefreshRequested() {
        DistributedNotificationCenter.default().postNotificationName(
            .busManualRefreshRequested,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - 手動更新

    /// 手動更新の要求。ウィジェットは複数配置できるため、
    /// 要求は対象ごと（停留所ごと）に持つ。共通のフラグ1個にすると、
    /// reloadAllTimelines() 後に最初へ到達したウィジェットだけが消費してしまう。
    static func requestManualRefresh(stopID: String?) {
        let key = stopID.map(Keys.manualRefresh) ?? Keys.manualRefreshAll
        defaults.set(Date().timeIntervalSince1970, forKey: key)
    }

    /// 手動更新の要求が有効かを判定する。
    /// 同じ停留所のウィジェットが複数あっても全てが更新できるよう、
    /// 消費（削除）はせず、猶予時間の経過で自然に無効化する。
    static func hasManualRefresh(stopID: String) -> Bool {
        let deadline = Date().timeIntervalSince1970 - manualRefreshWindow
        let forStop = defaults.double(forKey: Keys.manualRefresh(stopID))
        let forAll = defaults.double(forKey: Keys.manualRefreshAll)
        return forStop > deadline || forAll > deadline
    }

    /// ボタン押下からタイムライン生成までの遅延を見込んだ猶予
    private static let manualRefreshWindow: TimeInterval = 20

    // MARK: - メニューバー側で選んだバス停

    static var selectedRouteCode: String {
        get { defaults.string(forKey: Keys.routeCode) ?? BusStopConfig.defaultStop.routeCode }
        set { defaults.set(newValue, forKey: Keys.routeCode) }
    }

    static var selectedStopCode: String {
        get { defaults.string(forKey: Keys.stopCode) ?? BusStopConfig.defaultStop.code }
        set { defaults.set(newValue, forKey: Keys.stopCode) }
    }

    // MARK: - 最後に取得した状態

    /// 一時停止中は通信せずにこの値を表示する。取得時刻も一緒に持たせ、
    /// 値が古いことが分かるようにする。
    struct Snapshot: Codable {
        let message: String
        let observedAt: Date
    }

    static func saveSnapshot(_ snapshot: Snapshot, stopID: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.snapshot(stopID))
    }

    static func snapshot(stopID: String) -> Snapshot? {
        guard let data = defaults.data(forKey: Keys.snapshot(stopID)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
